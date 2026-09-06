import Fastify from 'fastify';
import type { FastifyRequest } from 'fastify';
import type { Pool, PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { digest, token, hashPassword, verifyPassword, dummyHash } from './auth.ts';
import type { User } from './auth.ts';
import { transaction } from './db.ts';
import { provisionRoutes } from './provision-api.ts';

declare module 'fastify' { interface FastifyRequest { actor: User | null } }
type DB = Pool | PoolClient;
class HttpError extends Error {
  statusCode: number;
  constructor(status: number, message: string) { super(message); this.statusCode = status; }
}
const forbid = () => { throw new HttpError(403, 'No tienes permiso para esta operación.'); };
const uuid = { type: 'string', format: 'uuid' };
const text = (max: number, min = 1) => ({ type: 'string', minLength: min, maxLength: max });
const label = { ...text(100), pattern: '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' };
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
const body = (properties: Record<string, unknown>, required?: string[]) => ({ schema: { body: object(properties, required) } });
const params = { schema: { params: object({ id: uuid }) } };
const withId = (options: ReturnType<typeof body>) => ({ schema: { ...options.schema, ...params.schema } });
const publicUser = (u: Record<string, any>): User => ({ id: u.id, name: u.name, email: u.email, role: u.role, system_admin: u.system_admin });
const sessionHash = (r: FastifyRequest) => {
  const value = /(?:^|;\s*)orquestador_session=([A-Za-z0-9_-]{43})(?:;|$)/.exec(r.headers.cookie ?? '')?.[1];
  return value ? digest(value) : '';
};
const audit = (db: DB, actor: string | null, action: string, resource: string | null = null) => db.query(
  'INSERT INTO audit(actor_id,action,resource_id) VALUES($1,$2,$3)', [actor, action, resource]);

async function manages(db: DB, actor: User, vmId: string) {
  if (actor.role !== 'admin') forbid();
  if (!actor.system_admin && !(await db.query('SELECT 1 FROM vm_admins WHERE vm_id=$1 AND user_id=$2', [vmId, actor.id])).rowCount) forbid();
}

export async function buildApi(pool: Pool, origin: string, webRoot?: string) {
  const url = new URL(origin);
  if (origin !== url.origin || (url.protocol !== 'https:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) {
    throw new Error('APP_ORIGIN debe ser un origen HTTPS; HTTP solo está permitido en localhost.');
  }
  const app = Fastify({ logger: false, bodyLimit: 32768, ajv: { customOptions: { removeAdditional: false, coerceTypes: false } } });
  app.decorateRequest('actor', null);
  const cookie = (value: string, maxAge: number) => `orquestador_session=${value}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}${url.protocol === 'https:' ? '; Secure' : ''}`;

  app.addHook('onRequest', async (request, reply) => {
    reply.header('Cache-Control', 'no-store').header('X-Content-Type-Options', 'nosniff')
      .header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    if (url.protocol === 'https:') reply.header('Strict-Transport-Security', 'max-age=31536000');
    if (!['GET', 'HEAD', 'OPTIONS'].includes(request.method) && request.headers.origin !== origin) {
      throw new HttpError(403, 'Origen de solicitud no autorizado.');
    }
    if (request.url === '/health' || request.url === '/api/login') return;
    if (webRoot && request.method === 'GET' && (request.url === '/' || /^\/assets\/[a-zA-Z0-9_.-]+\.(js|css)$/.test(request.url))) return;
    const result = await pool.query(`SELECT u.* FROM sessions s JOIN users u ON u.id=s.user_id
      WHERE s.token_hash=$1 AND s.expires_at>now() AND u.active`, [sessionHash(request)]);
    if (!result.rowCount) throw new HttpError(401, 'Inicia sesión para continuar.');
    request.actor = publicUser(result.rows[0]);
  });

  app.setErrorHandler(async (error, request, reply) => {
    const e = error as Error & { statusCode?: number; code?: string; validation?: unknown };
    const status = e.validation ? 400 : e.code === '23505' ? 409 : e.code === '23503' ? 400 : e.statusCode ?? 500;
    if (status === 403) await audit(pool, request.actor?.id ?? null, 'acceso_denegado').catch(() => {});
    const message = status >= 500 ? 'Error interno; revisa el servicio.' : e.validation ? 'Datos de solicitud inválidos.' : e.code === '23505' ? 'El registro ya existe.' : e.code === '23503' ? 'El recurso indicado no existe.' : e.message;
    reply.code(status).send({ error: message });
  });

  app.get('/health', async () => { await pool.query('SELECT 1'); return { status: 'ok' }; });
  if (webRoot) {
    app.get('/', async (_request, reply) => reply.type('text/html; charset=utf-8').send(await readFile(join(webRoot, 'index.html'))));
    app.get<{ Params: { file: string } }>('/assets/:file', async (request, reply) => {
      if (!/^[a-zA-Z0-9_-]+\.(js|css)$/.test(request.params.file)) throw new HttpError(404, 'Archivo no disponible.');
      try {
        return reply.type(request.params.file.endsWith('.js') ? 'application/javascript' : 'text/css').send(await readFile(join(webRoot, 'assets', request.params.file)));
      } catch { throw new HttpError(404, 'Archivo no disponible.'); }
    });
  }
  app.post<{ Body: { email: string; password: string } }>('/api/login', {
    ...body({ email: { ...text(254), format: 'email' }, password: text(256) })
  }, async (request, reply) => {
    const email = request.body.email.toLowerCase();
    // Persistente y compartido entre instancias. No se confía en X-Forwarded-For.
    for (const [key, limit] of [[digest(`email:${email}`), 10], [digest(`ip:${request.ip}`), 100]] as const) {
      const result = await pool.query(`INSERT INTO login_attempts(key,attempts,expires_at) VALUES($1,1,now()+interval '15 minutes')
        ON CONFLICT(key) DO UPDATE SET attempts=CASE WHEN login_attempts.expires_at<now() THEN 1 ELSE login_attempts.attempts+1 END,
        expires_at=CASE WHEN login_attempts.expires_at<now() THEN now()+interval '15 minutes' ELSE login_attempts.expires_at END RETURNING attempts`, [key]);
      if (result.rows[0].attempts > limit) { reply.header('Retry-After', '900'); throw new HttpError(429, 'Demasiados intentos. Intenta de nuevo más tarde.'); }
    }
    const found = (await pool.query('SELECT * FROM users WHERE email=$1', [email])).rows[0];
    const valid = await verifyPassword(request.body.password, found?.password_hash ?? dummyHash);
    if (!found?.active || !valid) { await audit(pool, null, 'inicio_sesion_rechazado'); throw new HttpError(401, 'Correo o contraseña incorrectos.'); }
    const session = token();
    await transaction(pool, async db => {
      // Bloquea una desactivación simultánea antes de crear la sesión.
      if (!(await db.query('SELECT 1 FROM users WHERE id=$1 AND active FOR SHARE', [found.id])).rowCount) throw new HttpError(401, 'Cuenta desactivada.');
      await db.query('DELETE FROM sessions WHERE expires_at<now()');
      await db.query("INSERT INTO sessions VALUES($1,$2,now()+interval '8 hours',now())", [digest(session), found.id]);
      await audit(db, found.id, 'inicio_sesion');
    });
    reply.header('Set-Cookie', cookie(session, 28800));
    return { user: publicUser(found) };
  });
  app.post('/api/logout', async (request, reply) => {
    await pool.query('DELETE FROM sessions WHERE token_hash=$1', [sessionHash(request)]);
    reply.header('Set-Cookie', cookie('', 0));
    return { ok: true };
  });
  app.get('/api/me', async request => ({ user: request.actor }));
  app.post<{ Body: { currentPassword: string; password: string } }>('/api/me/password', body({ currentPassword: text(256), password: text(256, 12) }), async (request, reply) => {
    const hash = await hashPassword(request.body.password);
    await transaction(pool, async db => {
      const user = (await db.query('SELECT * FROM users WHERE id=$1 FOR UPDATE', [request.actor!.id])).rows[0];
      if (!await verifyPassword(request.body.currentPassword, user.password_hash)) throw new HttpError(401, 'Contraseña actual incorrecta.');
      await db.query('UPDATE users SET password_hash=$2 WHERE id=$1', [user.id, hash]);
      await db.query('DELETE FROM sessions WHERE user_id=$1', [user.id]);
      await audit(db, user.id, 'cambio_contrasena');
    });
    reply.header('Set-Cookie', cookie('', 0));
    return { ok: true };
  });

  app.get('/api/targets', async request => ({ targets: (await pool.query(`SELECT t.*,v.name AS vm_name,g.can_read,g.can_write
    FROM targets t JOIN vms v ON v.id=t.vm_id JOIN grants g ON g.target_id=t.id
    WHERE g.user_id=$1 AND g.can_read AND t.active AND v.active ORDER BY t.name`, [request.actor!.id])).rows }));

  app.get('/api/admin/vms', async request => {
    if (request.actor!.role !== 'admin') forbid();
    return { vms: (await pool.query(`SELECT v.* FROM vms v WHERE $1 OR EXISTS
      (SELECT 1 FROM vm_admins a WHERE a.vm_id=v.id AND a.user_id=$2) ORDER BY name`, [request.actor!.system_admin, request.actor!.id])).rows };
  });
  app.post<{ Body: { name: string } }>('/api/admin/vms', body({ name: text(100) }), async (request, reply) => {
    if (!request.actor!.system_admin) forbid();
    const id = randomUUID();
    await transaction(pool, async db => {
      await db.query('INSERT INTO vms(id,name) VALUES($1,$2)', [id, request.body.name]);
      await audit(db, request.actor!.id, 'vm_creada', id);
    });
    return reply.code(201).send({ id });
  });
  app.put<{ Params: { id: string }; Body: { userId: string } }>('/api/admin/vms/:id/admin', withId(body({ userId: uuid })), async request => {
    if (!request.actor!.system_admin) forbid();
    await transaction(pool, async db => {
      if (!(await db.query("SELECT 1 FROM users WHERE id=$1 AND role='admin' AND active", [request.body.userId])).rowCount) throw new HttpError(400, 'Selecciona una cuenta administradora activa.');
      await db.query('INSERT INTO vm_admins VALUES($1,$2) ON CONFLICT DO NOTHING', [request.params.id, request.body.userId]);
      await audit(db, request.actor!.id, 'administrador_vm_asignado', request.params.id);
    });
    return { ok: true };
  });
  app.delete<{ Params: { id: string }; Body: { userId: string } }>('/api/admin/vms/:id/admin', withId(body({ userId: uuid })), async request => {
    if (!request.actor!.system_admin) forbid();
    await pool.query('DELETE FROM vm_admins WHERE vm_id=$1 AND user_id=$2', [request.params.id, request.body.userId]);
    await audit(pool, request.actor!.id, 'administrador_vm_retirado', request.params.id);
    return { ok: true };
  });
  app.post<{ Body: { email: string; name: string; password: string; role: 'admin' | 'operator' } }>('/api/admin/users', body({
    email: { ...text(254), format: 'email' }, name: text(100), password: text(256, 12), role: { enum: ['admin', 'operator'] }
  }), async (request, reply) => {
    const actor = request.actor!;
    if (actor.role !== 'admin' || (request.body.role === 'admin' && !actor.system_admin)) forbid();
    const id = randomUUID();
    const hash = await hashPassword(request.body.password);
    await transaction(pool, async db => {
      await db.query('INSERT INTO users(id,email,name,password_hash,role) VALUES($1,$2,$3,$4,$5)', [id, request.body.email.toLowerCase(), request.body.name, hash, request.body.role]);
      await audit(db, actor.id, 'usuario_creado', id);
    });
    return reply.code(201).send({ id });
  });
  app.get('/api/admin/users', async request => {
    if (request.actor!.role !== 'admin') forbid();
    return { users: (await pool.query(`SELECT u.id,u.email,u.name,u.role,u.active FROM users u WHERE $1 OR u.id=$2 OR EXISTS (
      SELECT 1 FROM grants g JOIN targets t ON t.id=g.target_id JOIN vm_admins a ON a.vm_id=t.vm_id
      WHERE g.user_id=u.id AND a.user_id=$2) OR EXISTS(SELECT 1 FROM audit a WHERE a.actor_id=$2 AND a.action='usuario_creado' AND a.resource_id=u.id::text)
      ORDER BY u.name`, [request.actor!.system_admin, request.actor!.id])).rows };
  });
  app.patch<{ Params: { id: string }; Body: { active: boolean } }>('/api/admin/users/:id', withId(body({ active: { type: 'boolean' } })), async request => {
    if (!request.actor!.system_admin || request.params.id === request.actor!.id) forbid();
    await transaction(pool, async db => {
      if (!(await db.query('UPDATE users SET active=$2 WHERE id=$1 RETURNING id', [request.params.id, request.body.active])).rowCount) throw new HttpError(404, 'Usuario inexistente.');
      if (!request.body.active) {
        await db.query('DELETE FROM sessions WHERE user_id=$1', [request.params.id]);
        await db.query("UPDATE jobs SET state=CASE WHEN state='queued' THEN 'cancelled' ELSE 'cancel_requested' END WHERE user_id=$1 AND state IN ('queued','running')", [request.params.id]);
      }
      await audit(db, request.actor!.id, request.body.active ? 'usuario_activado' : 'usuario_desactivado', request.params.id);
    });
    return { ok: true };
  });
  app.post<{ Body: { vmId: string; name: string; repository: string; container: string; stack: string } }>('/api/admin/targets', body({
    vmId: uuid, name: text(100), repository: label, container: label, stack: { enum: ['backend', 'frontend'] }
  }), async (request, reply) => {
    const b = request.body;
    const id = randomUUID();
    await transaction(pool, async db => {
      await manages(db, request.actor!, b.vmId);
      await db.query('INSERT INTO targets(id,vm_id,name,repository,container,stack) VALUES($1,$2,$3,$4,$5,$6)', [id, b.vmId, b.name, b.repository, b.container, b.stack]);
      await audit(db, request.actor!.id, 'destino_creado', id);
    });
    return reply.code(201).send({ id });
  });
  app.get('/api/admin/targets', async request => {
    if (request.actor!.role !== 'admin') forbid();
    return { targets: (await pool.query(`SELECT t.* FROM targets t WHERE $1 OR EXISTS
      (SELECT 1 FROM vm_admins a WHERE a.vm_id=t.vm_id AND a.user_id=$2) ORDER BY name`, [request.actor!.system_admin, request.actor!.id])).rows };
  });
  app.get<{ Params: { id: string } }>('/api/admin/targets/:id/grants', params, async request => {
    const target = (await pool.query('SELECT vm_id FROM targets WHERE id=$1', [request.params.id])).rows[0];
    if (!target) throw new HttpError(404, 'Destino inexistente.');
    await manages(pool, request.actor!, target.vm_id);
    return { grants: (await pool.query(`SELECT g.user_id,u.email,u.name,g.can_read,g.can_write FROM grants g JOIN users u ON u.id=g.user_id WHERE target_id=$1 ORDER BY u.name`, [request.params.id])).rows };
  });
  app.patch<{ Params: { id: string }; Body: { active: boolean } }>('/api/admin/targets/:id', withId(body({ active: { type: 'boolean' } })), async request => {
    await transaction(pool, async db => {
      const target = (await db.query('SELECT * FROM targets WHERE id=$1 FOR UPDATE', [request.params.id])).rows[0];
      if (!target) throw new HttpError(404, 'Destino inexistente.');
      await manages(db, request.actor!, target.vm_id);
      await db.query('UPDATE targets SET active=$2 WHERE id=$1', [target.id, request.body.active]);
      if (!request.body.active) await db.query("UPDATE jobs SET state=CASE WHEN state='queued' THEN 'cancelled' ELSE 'cancel_requested' END WHERE target_id=$1 AND state IN ('queued','running')", [target.id]);
      await audit(db, request.actor!.id, request.body.active ? 'destino_activado' : 'destino_desactivado', target.id);
    });
    return { ok: true };
  });
  app.put<{ Params: { id: string }; Body: { userId: string; canRead: boolean; canWrite: boolean } }>('/api/admin/targets/:id/grant', withId(body({ userId: uuid, canRead: { type: 'boolean' }, canWrite: { type: 'boolean' } })), async request => {
    const b = request.body;
    if (b.canWrite && !b.canRead) throw new HttpError(400, 'La escritura requiere permiso de lectura.');
    await transaction(pool, async db => {
      const target = (await db.query('SELECT * FROM targets WHERE id=$1 FOR UPDATE', [request.params.id])).rows[0];
      if (!target) throw new HttpError(404, 'Destino inexistente.');
      await manages(db, request.actor!, target.vm_id);
      await db.query(`INSERT INTO grants(user_id,target_id,can_read,can_write) VALUES($1,$2,$3,$4)
        ON CONFLICT(user_id,target_id) DO UPDATE SET can_read=$3,can_write=$4,version=grants.version+1`, [b.userId, target.id, b.canRead, b.canWrite]);
      await db.query(`UPDATE jobs SET state=CASE WHEN state='queued' THEN 'cancelled' ELSE 'cancel_requested' END
        WHERE user_id=$1 AND target_id=$2 AND state IN ('queued','running') AND (NOT $3 OR (NOT read_only AND NOT $4))`, [b.userId, target.id, b.canRead, b.canWrite]);
      await audit(db, request.actor!.id, 'permisos_actualizados', target.id);
      await db.query("INSERT INTO audit(actor_id,action,resource_id,details) VALUES($1,'detalle_asignacion',$2,$3)", [request.actor!.id, target.id, JSON.stringify({ user_id: b.userId, can_read: b.canRead, can_write: b.canWrite })]);
    });
    return { ok: true };
  });

  app.post<{ Body: { targetId: string; prompt: string; readOnly: boolean; idempotencyKey: string } }>('/api/jobs', body({
    targetId: uuid, prompt: text(20000), readOnly: { type: 'boolean' }, idempotencyKey: uuid
  }), async (request, reply) => {
    const b = request.body;
    if (!b.prompt.trim()) throw new HttpError(400, 'Escribe una solicitud.');
    const result = await transaction(pool, async db => {
      const vm = (await db.query('SELECT vm_id FROM targets WHERE id=$1', [b.targetId])).rows[0];
      if (vm) {
        await db.query('SELECT id FROM vms WHERE id=$1 FOR SHARE', [vm.vm_id]);
        if ((await db.query("SELECT 1 FROM preparations WHERE vm_id=$1 AND state IN ('queued','running','review')", [vm.vm_id])).rowCount) throw new HttpError(409, 'La VM está en preparación o revisión.');
      }
      const allowed = await db.query(`SELECT t.id FROM targets t JOIN vms v ON v.id=t.vm_id
        JOIN grants g ON g.target_id=t.id JOIN users u ON u.id=g.user_id
        WHERE t.id=$1 AND u.id=$2 AND u.active AND t.active AND v.active AND g.can_read
        AND ($3 OR g.can_write) FOR SHARE OF t,v,g,u`, [b.targetId, request.actor!.id, b.readOnly]);
      if (!allowed.rowCount) forbid();
      if (!(await db.query('SELECT 1 FROM targets WHERE id=$1 AND execution_ready', [b.targetId])).rowCount) throw new HttpError(409, 'El módulo está pendiente de preparación y verificación.');
      if ((await db.query("SELECT 1 FROM jobs WHERE user_id=$1 AND state IN ('queued','running','cancel_requested') LIMIT 20", [request.actor!.id])).rowCount! >= 20) throw new HttpError(429, 'Tienes demasiadas solicitudes pendientes.');
      await db.query(`INSERT INTO jobs(id,user_id,target_id,prompt,read_only,idempotency_key)
        VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id,idempotency_key) DO NOTHING`, [randomUUID(), request.actor!.id, b.targetId, b.prompt, b.readOnly, b.idempotencyKey]);
      const job = (await db.query('SELECT id,target_id,prompt,read_only,state FROM jobs WHERE user_id=$1 AND idempotency_key=$2', [request.actor!.id, b.idempotencyKey])).rows[0];
      if (job.target_id !== b.targetId || job.prompt !== b.prompt || job.read_only !== b.readOnly) throw new HttpError(409, 'La clave de solicitud ya se usó con otros datos.');
      await audit(db, request.actor!.id, 'solicitud_aceptada', job.id);
      return { id: job.id, state: job.state };
    });
    return reply.code(202).send(result);
  });
  const visibleJobs = `FROM jobs j JOIN grants g ON g.target_id=j.target_id AND g.user_id=j.user_id
    JOIN targets t ON t.id=j.target_id JOIN vms v ON v.id=t.vm_id
    WHERE j.user_id=$1 AND g.can_read AND t.active AND v.active`;
  app.get('/api/jobs', async request => ({ jobs: (await pool.query(`SELECT j.id,j.target_id,j.state,j.read_only,j.created_at,j.finished_at ${visibleJobs} ORDER BY j.created_at DESC LIMIT 100`, [request.actor!.id])).rows }));
  app.get<{ Params: { id: string } }>('/api/jobs/:id', params, async request => {
    const result = await pool.query(`SELECT j.id,j.target_id,j.prompt,j.state,j.read_only,j.result,j.created_at,j.finished_at ${visibleJobs} AND j.id=$2`, [request.actor!.id, request.params.id]);
    if (!result.rowCount) throw new HttpError(404, 'Solicitud no disponible.');
    return { job: result.rows[0] };
  });
  app.post<{ Params: { id: string } }>('/api/jobs/:id/cancel', params, async request => {
    const result = await pool.query(`UPDATE jobs SET state=CASE WHEN state='queued' THEN 'cancelled' ELSE 'cancel_requested' END
      WHERE id=$1 AND user_id=$2 AND state IN ('queued','running') RETURNING state`, [request.params.id, request.actor!.id]);
    if (!result.rowCount) throw new HttpError(409, 'La solicitud no puede cancelarse o no está disponible.');
    await audit(pool, request.actor!.id, 'cancelacion_solicitada', request.params.id);
    return result.rows[0];
  });
  await provisionRoutes(app, pool);
  return app;
}
