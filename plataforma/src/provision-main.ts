import { database } from './db.ts';
import { SSHPreparer, prepareOnce, quarantinePreparations } from './provisioner.ts';
import { fileURLToPath } from 'node:url';
import { setTimeout } from 'node:timers/promises';
const pool = database(process.env.DATABASE_URL ?? '');
const secret = process.env.PROVISION_PRIVATE, registry = process.env.WORKER_REGISTRY;
if (!secret || !registry) throw new Error('Faltan PROVISION_PRIVATE y WORKER_REGISTRY.');
const driver = new SSHPreparer(pool,fileURLToPath(new URL('../../',import.meta.url)),secret,registry);
const controller = new AbortController();
for (const s of ['SIGINT','SIGTERM'] as const) process.once(s,()=>controller.abort());
const pulse = async () => { await pool.query("INSERT INTO service_health VALUES('preparacion',now()) ON CONFLICT(name) DO UPDATE SET heartbeat_at=now()"); };
const timer = setInterval(()=>{ void pulse().catch(()=>controller.abort()); },5000);
try {
  while (!controller.signal.aborted) {
    await pulse(); await quarantinePreparations(pool);
    if (!await prepareOnce(pool,driver,controller.signal)) await setTimeout(1000,undefined,{signal:controller.signal});
  }
} catch { if (!controller.signal.aborted) { console.error('Se detuvo el servicio de preparación.'); process.exitCode=1; } }
finally { clearInterval(timer); await pool.end(); }
