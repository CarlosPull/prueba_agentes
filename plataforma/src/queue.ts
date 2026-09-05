import type { Pool } from 'pg';
import { randomUUID } from 'node:crypto';
import { transaction } from './db.ts';

export type Job = {
  id: string; user_id: string; target_id: string; prompt: string; read_only: boolean;
  worker_token: string; state: string; vm_id: string; container: string; repository: string; stack: string;
};

// No se reencolan ejecuciones perdidas: una caída no demuestra que el remoto se detuvo.
export async function quarantineStale(pool: Pool) {
  return pool.query(`UPDATE jobs SET state='reconciliation_required',result='Se perdió el contacto con el trabajador. Requiere conciliación administrativa.'
    WHERE state IN ('running','cancel_requested') AND heartbeat_at<now()-interval '2 minutes' RETURNING id`);
}

export async function claim(pool: Pool): Promise<Job | null> {
  return transaction(pool, async db => {
    // El bloqueo del destino y el índice único protegen contra varios trabajadores.
    const target = (await db.query(`SELECT t.* FROM targets t JOIN vms v ON v.id=t.vm_id
      WHERE t.active AND t.execution_ready AND v.active AND EXISTS(SELECT 1 FROM jobs j WHERE j.target_id=t.id AND j.state='queued')
      AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.target_id=t.id AND j.state IN ('running','cancel_requested','reconciliation_required'))
      ORDER BY t.id FOR UPDATE OF t SKIP LOCKED LIMIT 1`)).rows[0];
    if (!target) return null;
    const job = (await db.query("SELECT * FROM jobs WHERE target_id=$1 AND state='queued' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1", [target.id])).rows[0];
    if (!job) return null;
    const allowed = await db.query(`SELECT 1 FROM grants g JOIN users u ON u.id=g.user_id
      WHERE g.user_id=$1 AND g.target_id=$2 AND g.can_read AND u.active AND ($3 OR g.can_write) FOR SHARE OF g,u`, [job.user_id, job.target_id, job.read_only]);
    if (!allowed.rowCount) {
      await db.query("UPDATE jobs SET state='cancelled',finished_at=now() WHERE id=$1", [job.id]);
      return null;
    }
    const owner = randomUUID();
    await db.query("UPDATE jobs SET state='running',worker_token=$2,heartbeat_at=now(),started_at=now() WHERE id=$1", [job.id, owner]);
    await db.query("INSERT INTO audit(actor_id,action,resource_id) VALUES($1,'ejecucion_reservada',$2)", [job.user_id, job.id]);
    return { ...job, state: 'running', worker_token: owner, vm_id: target.vm_id, container: target.container, repository: target.repository, stack: target.stack };
  });
}

export async function heartbeat(pool: Pool, job: Job): Promise<boolean> {
  const changed = await pool.query(`UPDATE jobs j SET heartbeat_at=now() WHERE j.id=$1 AND j.worker_token=$2 AND j.state='running'
    AND EXISTS(SELECT 1 FROM grants g JOIN users u ON u.id=g.user_id JOIN targets t ON t.id=g.target_id JOIN vms v ON v.id=t.vm_id
    WHERE g.user_id=j.user_id AND g.target_id=j.target_id AND g.can_read AND (j.read_only OR g.can_write) AND u.active AND t.active AND v.active)`, [job.id, job.worker_token]);
  return changed.rowCount === 1;
}

export async function finish(pool: Pool, job: Job, state: 'succeeded' | 'failed' | 'reconciliation_required', result: string) {
  await transaction(pool, async db => {
    // Una revocación concurrente nunca se presenta como éxito al solicitante.
    const updated = await db.query(`UPDATE jobs SET state=CASE WHEN state='cancel_requested' THEN 'reconciliation_required' ELSE $3 END,
      result=$4,finished_at=now() WHERE id=$1 AND worker_token=$2 AND state IN ('running','cancel_requested') RETURNING state`,
    [job.id, job.worker_token, state, result.slice(0, 64000)]);
    if (updated.rowCount) await db.query('INSERT INTO audit(actor_id,action,resource_id) VALUES($1,$2,$3)', [job.user_id, `ejecucion_${updated.rows[0].state}`, job.id]);
  });
}

export interface Driver { run(job: Job, signal: AbortSignal): Promise<{ state: 'succeeded' | 'failed' | 'reconciliation_required'; result: string }> }

export async function workOnce(pool: Pool, driver: Driver, signal?: AbortSignal): Promise<boolean> {
  const job = await claim(pool);
  if (!job) return false;
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  let checking = false;
  const timer = setInterval(async () => {
    if (checking) return;
    checking = true;
    try { if (!await heartbeat(pool, job)) abort(); } catch { abort(); }
    finally { checking = false; }
  }, 1000);
  try {
    if (!await heartbeat(pool, job) || controller.signal.aborted) {
      await finish(pool, job, 'failed', 'La autorización dejó de estar vigente antes del despacho.');
    } else {
      const result = await driver.run(job, controller.signal);
      await finish(pool, job, result.state, result.result);
    }
  } catch {
    await finish(pool, job, 'reconciliation_required', 'No se pudo confirmar el estado remoto. No se reintentará automáticamente.');
  } finally {
    clearInterval(timer);
    signal?.removeEventListener('abort', abort);
  }
  return true;
}
