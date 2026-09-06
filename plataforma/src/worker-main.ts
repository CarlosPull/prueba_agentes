import { database } from './db.ts';
import { quarantineStale, workOnce } from './queue.ts';
import { OrchestratorDriver } from './driver.ts';
import { fileURLToPath } from 'node:url';
import { setTimeout } from 'node:timers/promises';

const pool = database(process.env.DATABASE_URL ?? '');
if (!process.env.WORKER_REGISTRY || !process.env.WORKER_RUNS) throw new Error('Configura WORKER_REGISTRY y WORKER_RUNS.');
const root = fileURLToPath(new URL('../../', import.meta.url));
const driver = new OrchestratorDriver(root, process.env.WORKER_REGISTRY, process.env.WORKER_RUNS);
const controller = new AbortController();
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => controller.abort());
const pulse = async () => { await pool.query("INSERT INTO service_health VALUES('ejecucion',now()) ON CONFLICT(name) DO UPDATE SET heartbeat_at=now()"); };
const timer = setInterval(() => { void pulse().catch(() => controller.abort()); }, 5000);
try {
  await pulse();
  while (!controller.signal.aborted) {
    await quarantineStale(pool);
    if (!await workOnce(pool, driver, controller.signal)) await setTimeout(1000, undefined, { signal: controller.signal });
  }
} catch (error) { if (!controller.signal.aborted) { console.error('El trabajador se detuvo; revisa la conexión a la base de datos.'); process.exitCode = 1; } }
finally { clearInterval(timer); await pool.end(); }
