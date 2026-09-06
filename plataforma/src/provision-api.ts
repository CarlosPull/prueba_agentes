import type { FastifyInstance } from 'fastify';
import type { Pool, PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { transaction } from './db.ts';
import type { User } from './auth.ts';

const uuid = { type: 'string', format: 'uuid' };
const str = (maxLength: number, pattern?: string) => ({ type: 'string', minLength: 1, maxLength, ...(pattern ? { pattern } : {}) });
const obj = (properties: Record<string, unknown>) => ({ type: 'object', additionalProperties: false, required: Object.keys(properties), properties });
const schema = (properties?: Record<string, unknown>) => ({ schema: { params: obj({ id: uuid }), ...(properties ? { body: obj(properties) } : {}) } });
function fail(statusCode: number, message: string): never { throw Object.assign(new Error(message), { statusCode }); }
async function manage(db: PoolClient, actor: User, vm: string) {
  if (actor.role !== 'admin' || (!actor.system_admin && !(await db.query('SELECT 1 FROM vm_admins WHERE vm_id=$1 AND user_id=$2', [vm, actor.id])).rowCount)) fail(403, 'No administras esta VM.');
}
async function idle(db: PoolClient, vm: string) {
  if ((await db.query("SELECT 1 FROM preparations WHERE vm_id=$1 AND state IN ('queued','running','review')", [vm])).rowCount) fail(409, 'La VM tiene una preparación activa o pendiente de revisión.');
  if ((await db.query("SELECT 1 FROM jobs j JOIN targets t ON t.id=j.target_id WHERE t.vm_id=$1 AND j.state IN ('queued','running','cancel_requested','reconciliation_required')", [vm])).rowCount) fail(409, 'Finaliza o concilia las tareas de esta VM antes de prepararla.');
}
export async function provisionRoutes(app: FastifyInstance, pool: Pool) {
  app.get('/api/admin/preparation/setup', async r => {
    if (!r.actor!.system_admin) fail(403, 'Solo el administrador general configura infraestructura.');
    let publicKey = '';
    try { publicKey = (await readFile(process.env.PROVISION_PUBLIC_KEY ?? '/etc/orquestador/provision_ed25519.pub', 'utf8')).trim(); } catch {}
    return { publicKey, available: publicKey.startsWith('ssh-ed25519 '), bootstrapUser: 'root' };
  });
  app.get('/api/admin/preparations', async r => {
    if (r.actor!.role !== 'admin') fail(403, 'Acceso administrativo requerido.');
    const scope = [r.actor!.system_admin, r.actor!.id];
    return {
      connections: (await pool.query(`SELECT c.* FROM vm_connections c WHERE $1 OR EXISTS(SELECT 1 FROM vm_admins a WHERE a.vm_id=c.vm_id AND a.user_id=$2)`, scope)).rows,
      sources: (await pool.query(`SELECT s.* FROM target_sources s JOIN targets t ON t.id=s.target_id WHERE $1 OR EXISTS(SELECT 1 FROM vm_admins a WHERE a.vm_id=t.vm_id AND a.user_id=$2)`, scope)).rows,
      preparations: (await pool.query(`SELECT p.* FROM preparations p WHERE $1 OR EXISTS(SELECT 1 FROM vm_admins a WHERE a.vm_id=p.vm_id AND a.user_id=$2) ORDER BY created_at DESC LIMIT 100`, scope)).rows,
      services: (await pool.query("SELECT name,heartbeat_at,heartbeat_at>now()-interval '30 seconds' AS available FROM service_health")).rows
    };
  });
  app.put<{ Params: { id: string }; Body: { host: string; port: number; fingerprint: string } }>('/api/admin/vms/:id/connection', schema({
    host: str(253, '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$'), port: { type: 'integer', minimum: 1, maximum: 65535 }, fingerprint: str(60, '^SHA256:[A-Za-z0-9+/]{43}$')
  }), async r => {
    if (!r.actor!.system_admin) fail(403, 'Solo el administrador general configura conexiones.');
    await transaction(pool, async db => {
      if (!(await db.query('SELECT id FROM vms WHERE id=$1 FOR UPDATE', [r.params.id])).rowCount) fail(404, 'VM inexistente.');
      await idle(db, r.params.id);
      if ((await db.query('SELECT 1 FROM targets WHERE vm_id=$1 AND execution_ready', [r.params.id])).rowCount) fail(409, 'La conexión de una VM con módulos preparados no puede sustituirse.');
      await db.query(`INSERT INTO vm_connections(vm_id,host,port,host_fingerprint) VALUES($1,$2,$3,$4)
        ON CONFLICT(vm_id) DO UPDATE SET host=$2,port=$3,host_fingerprint=$4,state='pending',message='Conexión actualizada; prepara la VM.',updated_at=now()`, [r.params.id, r.body.host, r.body.port, r.body.fingerprint]);
      await db.query("INSERT INTO audit(actor_id,action,resource_id) VALUES($1,'conexion_vm_configurada',$2)", [r.actor!.id, r.params.id]);
    });
    return { ok: true };
  });
  app.put<{ Params: { id: string }; Body: { gitUrl: string; branch: string; credentialProfile: string } }>('/api/admin/targets/:id/source', schema({
    gitUrl: str(1000, '^https://[a-zA-Z0-9][a-zA-Z0-9.-]*(?::[0-9]+)?/[a-zA-Z0-9._/-]+$'),
    branch: str(160, '^[a-zA-Z0-9][a-zA-Z0-9._/-]*$'), credentialProfile: str(64, '^[a-z][a-z0-9_-]*$')
  }), async r => {
    if (r.body.branch.includes('..') || r.body.branch.endsWith('/') || r.body.branch.includes('//')) fail(400, 'Rama no válida.');
    await transaction(pool, async db => {
      const t = (await db.query('SELECT * FROM targets WHERE id=$1', [r.params.id])).rows[0];
      if (!t) fail(404, 'Destino inexistente.');
      await db.query('SELECT id FROM vms WHERE id=$1 FOR UPDATE', [t.vm_id]);
      await manage(db, r.actor!, t.vm_id); await idle(db, t.vm_id);
      if (t.execution_ready) fail(409, 'No puedes sustituir la fuente de un módulo preparado. Crea otro destino.');
      const old = (await db.query('SELECT * FROM target_sources WHERE target_id=$1', [t.id])).rows[0];
      // Evita sustituir silenciosamente el código de un volumen tras un fallo parcial.
      if (old && (old.git_url !== r.body.gitUrl || old.git_branch !== r.body.branch || old.credential_profile !== r.body.credentialProfile)) fail(409, 'La fuente ya quedó registrada. Para cambiarla crea otro destino.');
      await db.query(`INSERT INTO target_sources(target_id,git_url,git_branch,credential_profile) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`, [t.id, r.body.gitUrl, r.body.branch, r.body.credentialProfile]);
      await db.query("INSERT INTO audit(actor_id,action,resource_id) VALUES($1,'fuente_modulo_configurada',$2)", [r.actor!.id, t.id]);
    });
    return { ok: true };
  });
  for (const kind of ['vms','targets'] as const) {
    app.post<{ Params: { id: string } }>(`/api/admin/${kind}/:id/prepare`, schema(), async (r, reply) => {
      const id = randomUUID();
      await transaction(pool, async db => {
        const t = kind === 'targets' ? (await db.query('SELECT * FROM targets WHERE id=$1', [r.params.id])).rows[0] : null;
        if (kind === 'targets' && !t) fail(404, 'Destino inexistente.');
        const vm = t?.vm_id ?? r.params.id;
        if (!(await db.query('SELECT id FROM vms WHERE id=$1 AND active FOR UPDATE', [vm])).rowCount) fail(404, 'VM no disponible.');
        await manage(db, r.actor!, vm);
        if (kind === 'vms' && !r.actor!.system_admin) fail(403, 'Solo el administrador general prepara la VM.');
        await idle(db, vm);
        const c = (await db.query('SELECT * FROM vm_connections WHERE vm_id=$1', [vm])).rows[0];
        if (!c || (t && c.state !== 'ready')) fail(409, 'Configura y prepara primero la conexión de la VM.');
        if (!t && (await db.query('SELECT 1 FROM targets WHERE vm_id=$1 AND execution_ready', [vm])).rowCount) fail(409, 'La VM ya tiene módulos preparados.');
        if (t && (!t.active || t.execution_ready || !(await db.query('SELECT 1 FROM target_sources WHERE target_id=$1', [t.id])).rowCount)) fail(409, 'Configura un módulo activo pendiente de preparación.');
        await db.query('INSERT INTO preparations(id,vm_id,target_id,actor_id) VALUES($1,$2,$3,$4)', [id, vm, t?.id ?? null, r.actor!.id]);
        if (t) await db.query("UPDATE target_sources SET state='queued',message='En cola',updated_at=now() WHERE target_id=$1", [t.id]);
        else await db.query("UPDATE vm_connections SET state='queued',message='En cola',updated_at=now() WHERE vm_id=$1", [vm]);
        await db.query("INSERT INTO audit(actor_id,action,resource_id) VALUES($1,'preparacion_solicitada',$2)", [r.actor!.id, id]);
      });
      return reply.code(202).send({ id });
    });
  }
}
