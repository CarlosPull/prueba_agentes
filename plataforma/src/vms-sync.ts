import type { Pool } from 'pg';
import { readFile, writeFile } from 'node:fs/promises';
import { transaction } from './db.ts';

export type UserPermissionEntry = {
  user_email: string;
  user_name: string;
  can_read: boolean;
  can_write: boolean;
};

export type VmConfigEntry = {
  ip: string;
  user: string;
  stack: 'backend' | 'frontend';
  dispatch_enabled?: boolean;
  workspace?: string;
  permissions?: UserPermissionEntry[];
  repositories?: Array<{
    id: string;
    module: string;
    kind?: string;
    path?: string;
    permissions?: UserPermissionEntry[];
  }>;
};

export type VmsConfigFile = Record<string, VmConfigEntry>;

export async function syncVmsConfigToDb(pool: Pool, vmsJsonPath: string) {
  let content = '';
  try {
    content = await readFile(vmsJsonPath, 'utf8');
  } catch {
    return;
  }
  const config = JSON.parse(content) as VmsConfigFile;

  await transaction(pool, async (db) => {
    for (const [profileName, entry] of Object.entries(config)) {
      if (!entry.ip || !entry.stack) continue;

      // 1. Sincronizar VM
      let vmId = '';
      const existingVm = (await db.query('SELECT id FROM vms WHERE name = $1', [profileName])).rows[0];
      if (existingVm) {
        vmId = existingVm.id;
      } else {
        const insertVm = await db.query(
          'INSERT INTO vms(id, name, active) VALUES(gen_random_uuid(), $1, true) RETURNING id',
          [profileName]
        );
        vmId = insertVm.rows[0].id;
      }

      // 2. Sincronizar Repositorios / Módulos
      const repos = entry.repositories && entry.repositories.length > 0
        ? entry.repositories
        : [{ id: profileName, module: profileName, kind: 'module', path: entry.workspace ?? '' }];

      for (const repo of repos) {
        const repoName = repo.id || repo.module || profileName;
        const containerName = `modulo-${repoName}`;

        const existingTarget = (await db.query(
          'SELECT id FROM targets WHERE vm_id = $1 AND repository = $2',
          [vmId, repoName]
        )).rows[0];

        if (!existingTarget) {
          await db.query(
            `INSERT INTO targets(id, vm_id, name, repository, container, stack, active, execution_ready)
             VALUES(gen_random_uuid(), $1, $2, $3, $4, $5, true, true)`,
            [vmId, `${profileName} (${repoName})`, repoName, containerName, entry.stack]
          );
        }
      }
    }
  });
}

export async function updateVmsJsonState(pool: Pool, vmsJsonPath: string) {
  try {
    const content = await readFile(vmsJsonPath, 'utf8');
    const config = JSON.parse(content) as VmsConfigFile;

    const query = `
      SELECT v.name AS vm_name, t.id AS target_id, t.repository, t.name AS target_name,
             u.email AS user_email, u.name AS user_name, g.can_read, g.can_write
      FROM grants g
      JOIN users u ON u.id = g.user_id
      JOIN targets t ON t.id = g.target_id
      JOIN vms v ON v.id = t.vm_id
      WHERE u.active AND t.active AND v.active AND (g.can_read OR g.can_write)
      ORDER BY v.name, u.email
    `;
    const rows = (await pool.query(query)).rows as Array<{
      vm_name: string;
      target_id: string;
      repository: string;
      target_name: string;
      user_email: string;
      user_name: string;
      can_read: boolean;
      can_write: boolean;
    }>;

    for (const [profileName, entry] of Object.entries(config)) {
      const vmRows = rows.filter(r => r.vm_name === profileName);

      const vmPermsMap = new Map<string, UserPermissionEntry>();
      for (const r of vmRows) {
        const existing = vmPermsMap.get(r.user_email);
        if (existing) {
          existing.can_read = existing.can_read || r.can_read;
          existing.can_write = existing.can_write || r.can_write;
        } else {
          vmPermsMap.set(r.user_email, {
            user_email: r.user_email,
            user_name: r.user_name,
            can_read: r.can_read,
            can_write: r.can_write
          });
        }
      }
      entry.permissions = Array.from(vmPermsMap.values());
      entry.dispatch_enabled = entry.permissions.some(p => p.can_read);

      if (entry.repositories && entry.repositories.length > 0) {
        for (const repo of entry.repositories) {
          const repoId = repo.id || repo.module || profileName;
          const repoRows = vmRows.filter(r => r.repository === repoId || r.target_name.includes(repoId));
          repo.permissions = repoRows.map(r => ({
            user_email: r.user_email,
            user_name: r.user_name,
            can_read: r.can_read,
            can_write: r.can_write
          }));
        }
      }
    }

    await writeFile(vmsJsonPath, JSON.stringify(config, null, 2), 'utf8');
  } catch (e) {
    console.error('Error actualizando config/vms.json:', e);
  }
}

