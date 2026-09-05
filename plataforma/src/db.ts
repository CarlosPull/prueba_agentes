import pg from 'pg';
import type { Pool, PoolClient } from 'pg';
import { readdir, readFile } from 'node:fs/promises';

export function database(url: string): Pool {
  if (!url) throw new Error('Falta DATABASE_URL.');
  return new pg.Pool({ connectionString: url, max: 10, connectionTimeoutMillis: 5000 });
}

export async function transaction<T>(pool: Pool, action: (db: PoolClient) => Promise<T>): Promise<T> {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const result = await action(db);
    await db.query('COMMIT');
    return result;
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  } finally { db.release(); }
}

export async function migrate(pool: Pool) {
  await transaction(pool, async db => {
    await db.query('SELECT pg_advisory_xact_lock(821753091)');
    await db.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY)');
    const directory = new URL('../migrations/', import.meta.url);
    for (const name of (await readdir(directory)).filter(n => /^\d+_[a-z_]+\.sql$/.test(n)).sort()) {
      if ((await db.query('SELECT 1 FROM schema_migrations WHERE name=$1', [name])).rowCount) continue;
      await db.query(await readFile(new URL(name, directory), 'utf8'));
      await db.query('INSERT INTO schema_migrations VALUES ($1)', [name]);
    }
  });
}
