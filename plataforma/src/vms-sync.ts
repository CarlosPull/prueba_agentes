import type { Pool } from 'pg';
import { readFile, writeFile } from 'node:fs/promises';
import { transaction } from './db.ts';

export type RepositoryConfigEntry = {
  id?: string;
  module?: string;
  kind?: string;
  path?: string;
  business_memory?: string;
  aliases?: string[];
  stack?: 'backend' | 'frontend';
  dispatch_enabled?: boolean;
  can_read?: boolean;
  can_write?: boolean;
  engine?: string;
  pi_harness?: string;
  pi_provider?: string;
  pi_model?: string;
  memory?: Record<string, unknown>;
  source_mode?: string;
  project_local_path?: string;
  agent_update_mode?: string;
  node_version?: string;
  pi_version?: string;
  php_version?: string;
  php_min_version?: string;
  install_dependencies?: boolean;
  local_agent?: string;
  remote_agent?: string;
  git_url?: string;
  git_branch?: string;
  git_agent_path?: string;
  agent_poll_seconds?: number;
  [key: string]: unknown;
};

export type UserConfigEntry = {
  name: string;
  repositories: RepositoryConfigEntry[];
};

export type VmConfigEntry = {
  ip: string;
  users?: UserConfigEntry[];
  repositories?: RepositoryConfigEntry[];
  user?: string;
  workspace?: string;
  stack?: 'backend' | 'frontend';
  dispatch_enabled?: boolean;
  [key: string]: unknown;
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
    const validVmNames = Object.keys(config);
    const validTargetKeys: Array<{ vmName: string; repoName: string }> = [];

    for (const [profileName, entry] of Object.entries(config)) {
      if (!entry.ip) continue;

      // 1. Sincronizar VM
      let vmId = '';
      const existingVm = (await db.query('SELECT id FROM vms WHERE name = $1', [profileName])).rows[0];
      if (existingVm) {
        vmId = existingVm.id;
        await db.query('UPDATE vms SET active = true WHERE id = $1', [vmId]);
      } else {
        const insertVm = await db.query(
          'INSERT INTO vms(id, name, active) VALUES(gen_random_uuid(), $1, true) RETURNING id',
          [profileName]
        );
        vmId = insertVm.rows[0].id;
      }

      // 2. Extraer repositorios
      const repos: RepositoryConfigEntry[] = [];
      if (Array.isArray(entry.users)) {
        for (const u of entry.users) {
          if (Array.isArray(u.repositories)) {
            for (const r of u.repositories) {
              if (!repos.some(existing => (existing.id || existing.module) === (r.id || r.module))) {
                repos.push(r);
              }
            }
          }
        }
      }
      if (repos.length === 0 && Array.isArray(entry.repositories)) {
        repos.push(...entry.repositories);
      }
      if (repos.length === 0) {
        repos.push({
          id: profileName,
          module: profileName,
          kind: 'module',
          path: entry.workspace ?? '',
          stack: entry.stack ?? 'backend'
        });
      }

      for (const repo of repos) {
        const repoName = repo.id || repo.module || profileName;
        const containerName = `modulo-${repoName}`;
        const stack = repo.stack || entry.stack || 'backend';

        validTargetKeys.push({ vmName: profileName, repoName });

        const existingTarget = (await db.query(
          'SELECT id FROM targets WHERE vm_id = $1 AND repository = $2',
          [vmId, repoName]
        )).rows[0];

        if (!existingTarget) {
          await db.query(
            `INSERT INTO targets(id, vm_id, name, repository, container, stack, active, execution_ready)
             VALUES(gen_random_uuid(), $1, $2, $3, $4, $5, true, true)`,
            [vmId, `${profileName} (${repoName})`, repoName, containerName, stack]
          );
        } else {
          await db.query('UPDATE targets SET active = true WHERE id = $1', [existingTarget.id]);
        }
      }
    }

    // Desactivar VMs eliminadas de vms.json
    if (validVmNames.length > 0) {
      await db.query('UPDATE vms SET active = false WHERE name NOT IN (SELECT unnest($1::text[]))', [validVmNames]);
    }

    // Desactivar Targets/Módulos eliminados de vms.json
    const allDbTargets = (await db.query('SELECT t.id, v.name AS vm_name, t.repository FROM targets t JOIN vms v ON v.id = t.vm_id')).rows;
    for (const t of allDbTargets) {
      const isStillValid = validTargetKeys.some(k => k.vmName === t.vm_name && k.repoName === t.repository);
      if (!isStillValid) {
        await db.query('UPDATE targets SET active = false WHERE id = $1', [t.id]);
      }
    }
  });
}

export async function updateVmsJsonState(pool: Pool, vmsJsonPath: string) {
  try {
    const content = await readFile(vmsJsonPath, 'utf8');
    const config = JSON.parse(content) as VmsConfigFile;

    const query = `
      SELECT v.name AS vm_name, t.id AS target_id, t.repository, t.name AS target_name, t.stack,
             u.id AS user_id, u.name AS user_name, u.email AS user_email,
             g.can_read, g.can_write
      FROM grants g
      JOIN users u ON u.id = g.user_id
      JOIN targets t ON t.id = g.target_id
      JOIN vms v ON v.id = t.vm_id
      WHERE u.active AND t.active AND v.active AND (g.can_read OR g.can_write)
      ORDER BY v.name, u.name
    `;
    const rows = (await pool.query(query)).rows as Array<{
      vm_name: string;
      target_id: string;
      repository: string;
      target_name: string;
      stack: 'backend' | 'frontend';
      user_id: string;
      user_name: string;
      user_email: string;
      can_read: boolean;
      can_write: boolean;
    }>;

    const newConfig: VmsConfigFile = {};

    for (const [profileName, entry] of Object.entries(config)) {
      const vmRows = rows.filter(r => r.vm_name === profileName);

      const repoTemplatesMap = new Map<string, RepositoryConfigEntry>();

      const topLevelDefaults: RepositoryConfigEntry = {};
      const technicalKeys = [
        'engine', 'pi_harness', 'pi_provider', 'pi_model', 'memory',
        'source_mode', 'project_local_path', 'agent_update_mode',
        'node_version', 'pi_version', 'php_version', 'php_min_version',
        'install_dependencies', 'local_agent', 'remote_agent', 'git_url',
        'git_branch', 'git_agent_path', 'agent_poll_seconds', 'aliases', 'business_memory'
      ];
      for (const k of technicalKeys) {
        if (entry[k] !== undefined) {
          topLevelDefaults[k] = entry[k] as any;
        }
      }

      if (Array.isArray(entry.users)) {
        for (const u of entry.users) {
          if (Array.isArray(u.repositories)) {
            for (const r of u.repositories) {
              const key = r.id || r.module || profileName;
              if (!repoTemplatesMap.has(key)) {
                repoTemplatesMap.set(key, { ...topLevelDefaults, ...r });
              }
            }
          }
        }
      }
      if (Array.isArray(entry.repositories)) {
        for (const r of entry.repositories) {
          const key = r.id || r.module || profileName;
          if (!repoTemplatesMap.has(key)) {
            repoTemplatesMap.set(key, { ...topLevelDefaults, ...r });
          }
        }
      }

      const usersMap = new Map<string, UserConfigEntry>();

      for (const r of vmRows) {
        let userEntry = usersMap.get(r.user_name);
        if (!userEntry) {
          userEntry = {
            name: r.user_name,
            repositories: []
          };
          usersMap.set(r.user_name, userEntry);
        }

        const repoKey = r.repository;
        const template = repoTemplatesMap.get(repoKey) ?? {
          ...topLevelDefaults,
          id: repoKey,
          module: repoKey,
          kind: profileName.includes('core') ? 'core' : profileName.includes('frontend') ? 'frontend' : 'module',
          path: entry.workspace ?? `/home/${r.user_name.toLowerCase()}/${repoKey}`,
          stack: r.stack || entry.stack || 'backend'
        };

        const userPath = template.path ? template.path.replace(/\/home\/[^/]+\//, `/home/${r.user_name.toLowerCase()}/`) : template.path;
        const userBusinessMemory = template.business_memory ? template.business_memory.replace(/\/home\/[^/]+\//, `/home/${r.user_name.toLowerCase()}/`) : template.business_memory;

        const repoObj: RepositoryConfigEntry = {
          id: template.id || repoKey,
          module: template.module || repoKey,
          kind: template.kind || 'module',
          path: userPath,
          business_memory: userBusinessMemory,
          aliases: template.aliases ?? [repoKey],
          stack: template.stack || r.stack || entry.stack || 'backend',
          engine: template.engine ?? 'pi',
          dispatch_enabled: r.can_read,
          can_read: r.can_read,
          can_write: r.can_write,
          pi_harness: template.pi_harness,
          pi_provider: template.pi_provider,
          pi_model: template.pi_model,
          memory: template.memory,
          source_mode: template.source_mode,
          project_local_path: template.project_local_path,
          agent_update_mode: template.agent_update_mode,
          node_version: template.node_version,
          pi_version: template.pi_version,
          php_version: template.php_version,
          php_min_version: template.php_min_version,
          install_dependencies: template.install_dependencies,
          local_agent: template.local_agent,
          remote_agent: template.remote_agent,
          git_url: template.git_url,
          git_branch: template.git_branch,
          git_agent_path: template.git_agent_path,
          agent_poll_seconds: template.agent_poll_seconds
        };

        // Clean undefined properties
        for (const k of Object.keys(repoObj)) {
          if (repoObj[k] === undefined) delete repoObj[k];
        }

        userEntry.repositories.push(repoObj);
      }

      newConfig[profileName] = {
        ip: entry.ip,
        users: Array.from(usersMap.values())
      };
    }

    await writeFile(vmsJsonPath, JSON.stringify(newConfig, null, 2), 'utf8');
  } catch (e) {
    console.error('Error actualizando config/vms.json:', e);
  }
}
