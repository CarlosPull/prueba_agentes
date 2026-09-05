import { database } from './db.ts';
import { buildApi } from './api.ts';
import { fileURLToPath } from 'node:url';

const pool = database(process.env.DATABASE_URL ?? '');
const app = await buildApi(pool, process.env.APP_ORIGIN ?? 'http://127.0.0.1:3100', fileURLToPath(new URL('../public/', import.meta.url)));
await app.listen({ host: process.env.HOST ?? '127.0.0.1', port: Number(process.env.PORT ?? 3100) });
console.log('API del orquestador disponible.');
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await app.close(); await pool.end(); });
