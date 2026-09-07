import type { Pool } from 'pg';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { transaction } from './db.ts';

export type Preparation = { id: string; vm_id: string; target_id: string | null; actor_id: string; worker_token: string };
export interface Preparer { run(p: Preparation, stage: (message: string) => Promise<void>, signal: AbortSignal): Promise<void> }
export async function prepareOnce(pool: Pool, driver: Preparer, signal: AbortSignal): Promise<boolean> {
  const p: Preparation | undefined = await transaction(pool, async db => {
    const p = (await db.query("SELECT * FROM preparations WHERE state='queued' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1")).rows[0];
    if (!p) return;
    const allowed = (await db.query(`SELECT 1 FROM users u WHERE u.id=$1 AND u.active AND u.role='admin'
      AND (u.system_admin OR ($3::uuid IS NOT NULL AND EXISTS(SELECT 1 FROM vm_admins a WHERE a.user_id=u.id AND a.vm_id=$2)))`, [p.actor_id,p.vm_id,p.target_id])).rowCount;
    if (!allowed) {
      await db.query("UPDATE preparations SET state='failed',stage='Autorización retirada',finished_at=now() WHERE id=$1", [p.id]);
      return;
    }
    p.worker_token = randomUUID();
    await db.query("UPDATE preparations SET state='running',stage='Conectando',worker_token=$2,heartbeat_at=now() WHERE id=$1", [p.id, p.worker_token]);
    return p;
  });
  if (!p) return false;
  const controller = new AbortController();
  const stop = () => controller.abort();
  signal.addEventListener('abort', stop, { once: true }); if (signal.aborted) stop();
  let checking = false;
  const pulse = setInterval(async () => {
    if (checking) return; checking = true;
    try {
      const ok = await pool.query(`UPDATE preparations p SET heartbeat_at=now() WHERE p.id=$1 AND p.worker_token=$2 AND p.state='running'
        AND EXISTS(SELECT 1 FROM users u WHERE u.id=p.actor_id AND u.active AND u.role='admin'
        AND (u.system_admin OR (p.target_id IS NOT NULL AND EXISTS(SELECT 1 FROM vm_admins a WHERE a.vm_id=p.vm_id AND a.user_id=u.id))))`, [p.id, p.worker_token]);
      if (!ok.rowCount) stop();
    } catch { stop(); } finally { checking = false; }
  }, 1000);
  const stage = async (message: string) => {
    await pool.query("UPDATE preparations SET stage=$3 WHERE id=$1 AND worker_token=$2 AND state='running'", [p.id,p.worker_token,message]);
    if (p.target_id) await pool.query("UPDATE target_sources SET state='preparing',message=$2,updated_at=now() WHERE target_id=$1", [p.target_id,message]);
    else await pool.query("UPDATE vm_connections SET state='preparing',message=$2,updated_at=now() WHERE vm_id=$1", [p.vm_id,message]);
  };
  let state = 'succeeded', message = 'Preparación y verificaciones completadas.';
  try { if (controller.signal.aborted) throw new Error('Interrumpido'); await driver.run(p, stage, controller.signal); }
  catch (error) {
    // Solo errores tipados y redactados por el ejecutor se muestran en la web.
    state = controller.signal.aborted || !(error instanceof PreparationError) || error.uncertain ? 'review' : 'failed';
    message = error instanceof PreparationError ? error.message : 'Se perdió confirmación; revisar el remoto antes de reintentar.';
  } finally { clearInterval(pulse); signal.removeEventListener('abort', stop); }
  await transaction(pool, async db => {
    // No habilitar si el administrador fue desactivado/revocado durante la operación.
    const auth = (await db.query(`SELECT 1 FROM users u WHERE u.id=$1 AND u.active AND u.role='admin'
      AND (u.system_admin OR ($3::uuid IS NOT NULL AND EXISTS(SELECT 1 FROM vm_admins a WHERE a.user_id=u.id AND a.vm_id=$2))) FOR SHARE OF u`, [p.actor_id,p.vm_id,p.target_id])).rowCount;
    if (!auth || signal.aborted || controller.signal.aborted) { state = 'review'; message = 'Preparación interrumpida o autorización retirada; revisar el remoto.'; }
    const changed = await db.query("UPDATE preparations SET state=$3,stage=$4,finished_at=now() WHERE id=$1 AND worker_token=$2 AND state='running' RETURNING id", [p.id,p.worker_token,state,message]);
    if (!changed.rowCount) return;
    const resourceState = state === 'succeeded' ? 'ready' : state;
    if (p.target_id) {
      await db.query('UPDATE target_sources SET state=$2,message=$3,updated_at=now() WHERE target_id=$1', [p.target_id,resourceState,message]);
      await db.query('UPDATE targets SET execution_ready=$2 WHERE id=$1', [p.target_id,state === 'succeeded']);
    } else await db.query('UPDATE vm_connections SET state=$2,message=$3,updated_at=now() WHERE vm_id=$1', [p.vm_id,resourceState,message]);
    await db.query('INSERT INTO audit(actor_id,action,resource_id,details) VALUES($1,$2,$3,$4)', [p.actor_id,`preparacion_${state}`,p.id,JSON.stringify({ vm_id:p.vm_id,target_id:p.target_id })]);
  });
  return true;
}
export class PreparationError extends Error {
  uncertain: boolean;
  constructor(message: string, uncertain = false) { super(message); this.uncertain = uncertain; }
}
export async function quarantinePreparations(pool: Pool) {
  await transaction(pool, async db => {
    const stale = (await db.query("UPDATE preparations SET state='review',stage='Trabajador sin contacto; revisar remoto',finished_at=now() WHERE state='running' AND heartbeat_at<now()-interval '2 minutes' RETURNING *")).rows;
    for (const p of stale) {
      if (p.target_id) {
        await db.query("UPDATE target_sources SET state='review',message='Sin confirmación remota',updated_at=now() WHERE target_id=$1", [p.target_id]);
        await db.query('UPDATE targets SET execution_ready=false WHERE id=$1', [p.target_id]);
      } else await db.query("UPDATE vm_connections SET state='review',message='Sin confirmación remota',updated_at=now() WHERE vm_id=$1", [p.vm_id]);
    }
  });
}
// Ejecución sin shell local, entradas por stdin y mensajes públicos acotados.
export function command(program: string, args: string[], input: string | Buffer, signal: AbortSignal, timeout = 1800000): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(program,args,{stdio:['pipe','pipe','pipe'],signal,timeout,killSignal:'SIGTERM'});
    let out = '', overflow = false;
    child.stdout.on('data', b => { out += b.toString(); if (out.length > 1024*1024) { overflow = true; child.kill(); } });
    child.stderr.resume(); // No publicar salida de comandos que pudiera contener secretos.
    child.stdin.on('error', () => {}); child.stdin.end(input);
    child.on('error', reject);
    child.on('close', code => code === 0 && !overflow ? resolve(out) : reject(new PreparationError(`La operación remota falló (código ${code ?? 'sin confirmación'}). Comprueba SSH, paquetes y aislamiento.`, code === 255 || code === null)));
  });
}
export class SSHPreparer implements Preparer {
  private pool: Pool;
  private root: string;
  private privateDir: string;
  private registry: string;

  constructor(pool: Pool, root: string, privateDir: string, registry: string) {
    this.pool = pool;
    this.root = root;
    this.privateDir = privateDir;
    this.registry = registry;
  }
  async run(p: Preparation, stage: (s: string) => Promise<void>, signal: AbortSignal) {
    const c = (await this.pool.query('SELECT * FROM vm_connections WHERE vm_id=$1',[p.vm_id])).rows[0];
    if (!c || !/^[a-zA-Z0-9][a-zA-Z0-9.:-]*$/.test(c.host) || !Number.isInteger(c.port)) throw new PreparationError('Conexión no válida.');
    await stage('Verificando identidad SSH');
    const dir = join(this.registry,'hosts'); await mkdir(dir,{recursive:true,mode:0o700});
    const scanned = await command('ssh-keyscan',['-T','8','-p',String(c.port),'-t','ed25519',c.host],'',signal,15000);
    const lines = scanned.split('\n').filter(l => l && !l.startsWith('#'));
    if (lines.length !== 1) throw new PreparationError('La VM no devolvió una identidad SSH única.');
    const fingerprint = await command('ssh-keygen',['-lf','-'],lines[0]+'\n',signal,10000);
    if (fingerprint.split(/\s+/)[1] !== c.host_fingerprint) throw new PreparationError('La huella SSH no coincide con la registrada. No se enviaron credenciales.');
    const known = join(dir,`${p.vm_id}.known_hosts`); await writeFile(known,lines[0]+'\n',{mode:0o600});
    const ssh = ['-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',`UserKnownHostsFile=${known}`,'-i',join(this.privateDir,'provision_ed25519'),'-p',String(c.port),`root@${c.host}`];
    await stage('Comprobando llave de preparación');
    await command('ssh',[...ssh,'test "$(id -u)" = 0'],'',signal,20000);
    await stage('Transfiriendo herramientas revisadas');
    const archive = await readFile(join(this.root,'plataforma/provision-bundle.tar'));
    // Ruta fija: no se interpola entrada del navegador en una orden shell.
    await command('ssh',[...ssh,'install -d -m 700 /var/lib/orquestador-installer && tar -xf - -C /var/lib/orquestador-installer'],archive,signal);
    const execPublic = (await readFile(join(this.privateDir,'execution_ed25519.pub'),'utf8')).trim();
    let payload: Record<string,unknown> = { vm_id:p.vm_id,job_id:p.id,execution_key:execPublic };
    if (p.target_id) {
      const t = (await this.pool.query('SELECT t.*,s.git_url,s.git_branch,s.credential_profile FROM targets t JOIN target_sources s ON s.target_id=t.id WHERE t.id=$1',[p.target_id])).rows[0];
      if (!t || !/^[a-z][a-z0-9_-]{0,63}$/.test(t.credential_profile)) throw new PreparationError('Fuente no disponible.');
      let profile;
      try { profile = JSON.parse(await readFile(join(this.privateDir,'profiles',`${t.credential_profile}.json`),'utf8')); } catch { throw new PreparationError('El perfil de credenciales no está instalado en el servidor.'); }
      if (!Array.isArray(profile.allowedVmIds) || !profile.allowedVmIds.includes(p.vm_id)) throw new PreparationError('El perfil de credenciales no está autorizado para esta VM.');
      if (!['anthropic','openai'].includes(profile.provider) || typeof profile.apiKey !== 'string' || !profile.apiKey || /[\r\n]/.test(profile.apiKey) || typeof profile.model !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,159}$/.test(profile.model)) throw new PreparationError('Perfil Pi inválido.');
      payload = {...payload,target:t,credentials:profile};
    }
    await stage(p.target_id ? 'Construyendo módulo, clonando y verificando aislamiento' : 'Instalando Podman y usuario de servicio');
    const result = await command('ssh',[...ssh,'timeout --kill-after=30s 25m bash /var/lib/orquestador-installer/plataforma/remoto/preparar.sh'],JSON.stringify(payload),signal);
    const marker = result.trim().split('\n').at(-1);
    if (marker !== 'ORQUESTADOR_PREPARADO_V1') throw new PreparationError('El remoto no confirmó las verificaciones.',true);
    if (p.target_id) {
      const t = payload.target as Record<string,string>;
      await mkdir(this.registry,{recursive:true,mode:0o700});
      const connection = {host:c.host,user:'orquestador',port:c.port,identityFile:join(this.privateDir,'execution_ed25519'),knownHostsFile:known,container:t.container,repository:t.repository,stack:t.stack,isolationVerified:true};
      const final = join(this.registry,`${p.target_id}.json`), temporary = `${final}.${p.id}.tmp`;
      await writeFile(temporary,JSON.stringify(connection),{mode:0o600}); await rename(temporary,final);
    }
    await stage('Verificación completada');
  }
}
