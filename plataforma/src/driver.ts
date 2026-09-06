import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { Driver, Job } from './queue.ts';

export type Connection = { host: string; user: string; port: number; identityFile: string; knownHostsFile: string; container: string; repository: string; stack: string; isolationVerified: boolean };

export function validateConnection(value: Connection): void {
  if (!value || !/^[a-zA-Z0-9][a-zA-Z0-9.:-]*$/.test(value.host) || !/^[a-z_][a-z0-9_-]*$/.test(value.user)
    || !Number.isInteger(value.port) || value.port < 1 || value.port > 65535
    || ![value.identityFile, value.knownHostsFile].every(p => typeof p === 'string' && p.startsWith('/') && !/[\r\n]/.test(p))
    || ![value.container, value.repository].every(p => typeof p === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(p))
    || !['backend', 'frontend'].includes(value.stack) || value.isolationVerified !== true) {
    throw new Error('Conexión no registrada o aislamiento pendiente de verificar.');
  }
}

// El registro es administrado fuera de la API; las solicitudes nunca eligen claves o rutas.
export class OrchestratorDriver implements Driver {
  root: string; registryPath: string; runs: string;
  constructor(root: string, registryPath: string, runs: string) { this.root = resolve(root); this.registryPath = registryPath; this.runs = resolve(runs); }
  async run(job: Job, signal: AbortSignal) {
    const isDirectory = (await stat(this.registryPath)).isDirectory();
    const registry = JSON.parse(await readFile(isDirectory ? join(this.registryPath, `${job.target_id}.json`) : this.registryPath, 'utf8'));
    const connection = (isDirectory ? registry : registry[job.target_id]) as Connection;
    try { validateConnection(connection); } catch {
      return { state: 'failed' as const, result: 'Destino pendiente de provisionar y verificar en el registro del trabajador.' };
    }
    if (connection.container !== job.container || connection.repository !== job.repository || connection.stack !== job.stack) {
      return { state: 'failed' as const, result: 'El registro remoto no coincide con el destino autorizado.' };
    }
    await mkdir(this.runs, { recursive: true, mode: 0o700 });
    const directory = await mkdtemp(join(this.runs, `${job.id}-`));
    const config = {
      [job.target_id]: { ip: connection.host, user: connection.user, stack: job.stack, engine: 'pi', dispatch_enabled: true,
        workspace: '/workspace', memory: { enabled: false },
        repositories: [{ id: job.repository, module: job.repository, kind: 'module', path: '/workspace', business_memory: '', aliases: [job.repository] }] }
    };
    await writeFile(join(directory, 'vms.json'), JSON.stringify(config), { mode: 0o600 });
    await writeFile(join(directory, 'tecnologias.json'), '{"version":1,"repositories":{}}', { mode: 0o600 });
    await writeFile(join(directory, 'connection.json'), JSON.stringify(connection), { mode: 0o600 });
    const env = {
      PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8',
      PRUEBA_AGENTES_VMS_CONF: join(directory, 'vms.json'),
      PRUEBA_AGENTES_PRIVATE_TECH_MEMORY: join(directory, 'tecnologias.json'),
      PRUEBA_AGENTES_PRIVATE_MEMORY_REQUIRED: '1', PRUEBA_AGENTES_DISABLE_LLM_ANALYSIS: '1',
      PRUEBA_AGENTES_PROJECTS_DIR: join(directory, 'proyectos'),
      PRUEBA_AGENTES_DIAGNOSTICO_VMS: 'true',
      PRUEBA_AGENTES_DESPACHADOR: join(this.root, 'plataforma/bin/despachar_podman.sh'),
      PLATFORM_CONNECTION_FILE: join(directory, 'connection.json'), PLATFORM_JOB_ID: job.id,
      PLATFORM_TARGET_ID: job.target_id, PLATFORM_USER_ID: job.user_id, PLATFORM_READ_ONLY: job.read_only ? '1' : '0'
    };
    // La política viaja por separado y no puede ser sustituida por el contenido del prompt.
    const prompt = `${job.read_only ? 'Solo lectura, sin modificar archivos. ' : ''}En ${job.repository} (${job.stack === 'backend' ? 'backend Laravel' : 'frontend Vue'}): ${job.prompt}`;
    return new Promise<{ state: 'succeeded' | 'failed' | 'reconciliation_required'; result: string }>((resolvePromise, reject) => {
      const child = spawn(join(this.root, 'tools/orquestacion/orquestar.sh'), [prompt], { env, signal, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      const collect = (data: Buffer) => { output = (output + data.toString('utf8')).slice(-64000); };
      child.stdout.on('data', collect); child.stderr.on('data', collect);
      const stop = () => { if (child.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} } };
      signal.addEventListener('abort', stop, { once: true });
      child.once('error', error => { signal.removeEventListener('abort', stop); reject(error); });
      child.once('close', async code => {
        signal.removeEventListener('abort', stop);
        if (signal.aborted) { resolvePromise({ state: 'reconciliation_required', result: 'Cancelación solicitada. Verificar el estado remoto antes de continuar.' }); return; }
        // Solo devolver la salida saneada del ejecutor; las rutas locales no van a la API.
        try {
          const result = await readFile(join(directory, 'resultado.txt'), 'utf8');
          resolvePromise({ state: code === 0 ? 'succeeded' : 'reconciliation_required', result });
        } catch {
          // Si la conexión pudo iniciarse, cualquier ausencia de confirmación se concilia.
          resolvePromise({ state: 'reconciliation_required', result: 'No hay confirmación remota. Revisa la evidencia administrativa.' });
        }
        await writeFile(join(directory, 'worker.log'), output, { mode: 0o600 }).catch(() => {});
      });
    });
  }
}
