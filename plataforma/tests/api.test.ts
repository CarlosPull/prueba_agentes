import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { database, migrate } from '../src/db.ts';
import { hashPassword } from '../src/auth.ts';
import { buildApi } from '../src/api.ts';
import { claim, heartbeat, finish, quarantineStale, workOnce } from '../src/queue.ts';
import { validateConnection } from '../src/driver.ts';

const url = process.env.DATABASE_TEST_URL;
if (!url || !new URL(url).pathname.endsWith('_pruebas')) throw new Error('DATABASE_TEST_URL debe apuntar a una base exclusiva terminada en _pruebas. Usa bin/probar_podman.sh.');
const pool = database(url);
const origin = 'http://127.0.0.1:3100';
const app = await buildApi(pool, origin);
const password = 'Contraseña de prueba exclusiva 2026';
const ids = { root: randomUUID(), admin: randomUUID(), alice: randomUUID(), bob: randomUUID(), vm: randomUUID(), otherVm: randomUUID(), a: randomUUID(), b: randomUUID() };
let hash: string;
before(async () => { await migrate(pool); await migrate(pool); hash = await hashPassword(password); await app.ready(); });
after(async () => { await app.close(); await pool.end(); });
beforeEach(async () => {
  await pool.query('TRUNCATE audit,jobs,grants,targets,vm_admins,vms,sessions,login_attempts,users CASCADE');
  for (const name of ['root', 'admin', 'alice', 'bob'] as const) await pool.query('INSERT INTO users(id,email,name,password_hash,role,system_admin) VALUES($1,$2,$3,$4,$5,$6)',
    [ids[name], `${name}@example.test`, name, hash, ['root', 'admin'].includes(name) ? 'admin' : 'operator', name === 'root']);
  await pool.query("INSERT INTO vms VALUES($1,'VM asignada',true),($2,'VM ajena',true)", [ids.vm, ids.otherVm]);
  await pool.query('INSERT INTO vm_admins VALUES($1,$2)', [ids.vm, ids.admin]);
  await pool.query("INSERT INTO targets(id,vm_id,name,repository,container,stack,execution_ready) VALUES($1,$3,'Comentarios','comments','comments','backend',true),($2,$3,'Pagos','pagos','pagos','backend',true)", [ids.a, ids.b, ids.vm]);
  await pool.query('INSERT INTO grants(user_id,target_id,can_read,can_write) VALUES($1,$2,true,true),($3,$4,true,false)', [ids.alice, ids.a, ids.bob, ids.b]);
});

async function login(name: string) {
  const response = await app.inject({ method: 'POST', url: '/api/login', headers: { origin }, payload: { email: `${name}@example.test`, password } });
  assert.equal(response.statusCode, 200, response.body);
  return String(response.headers['set-cookie']).split(';')[0];
}
async function createJob(cookie: string, targetId = ids.a, readOnly = true, key = randomUUID()) {
  return app.inject({ method: 'POST', url: '/api/jobs', headers: { cookie, origin }, payload: { targetId, readOnly, prompt: 'Analiza los endpoints Laravel de comments', idempotencyKey: key } });
}

test('sesión persistente, cookie protegida y cierre efectivo', async () => {
  const response = await app.inject({ method: 'POST', url: '/api/login', headers: { origin }, payload: { email: 'alice@example.test', password } });
  assert.equal(response.statusCode, 200);
  const cookie = String(response.headers['set-cookie']);
  assert.match(cookie, /HttpOnly/); assert.match(cookie, /SameSite=Strict/);
  const stored = (await pool.query('SELECT token_hash FROM sessions')).rows[0].token_hash;
  assert.equal(cookie.includes(stored), false);
  const headers = { cookie: cookie.split(';')[0], origin };
  assert.equal((await app.inject({ url: '/api/me', headers })).statusCode, 200);
  await app.inject({ method: 'POST', url: '/api/logout', headers });
  assert.equal((await app.inject({ url: '/api/me', headers })).statusCode, 401);
});

test('rechaza CSRF, propiedades no admitidas y UUID inválidos', async () => {
  const cookie = await login('alice');
  assert.equal((await app.inject({ method: 'POST', url: '/api/logout', headers: { cookie } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'POST', url: '/api/jobs', headers: { cookie, origin }, payload: { targetId: ids.a, readOnly: true, prompt: 'Prueba', idempotencyKey: randomUUID(), shell: 'otro' } })).statusCode, 400);
  assert.equal((await app.inject({ url: '/api/jobs/invalido', headers: { cookie } })).statusCode, 400);
});

test('usuarios en una misma VM solo ven y ejecutan en su módulo', async () => {
  const cookie = await login('alice');
  const targets = (await app.inject({ url: '/api/targets', headers: { cookie } })).json().targets;
  assert.deepEqual(targets.map((t: any) => t.id), [ids.a]);
  assert.equal((await createJob(cookie, ids.b)).statusCode, 403);
  assert.equal((await createJob(cookie)).statusCode, 202);
});

test('lectura no concede escritura ni acceso administrativo', async () => {
  const cookie = await login('bob');
  assert.equal((await createJob(cookie, ids.b, false)).statusCode, 403);
  assert.equal((await createJob(cookie, ids.b, true)).statusCode, 202);
  assert.equal((await app.inject({ url: '/api/admin/users', headers: { cookie } })).statusCode, 403);
});

test('administrador delegado no administra otra VM ni obtiene ejecución implícita', async () => {
  const cookie = await login('admin');
  assert.deepEqual((await app.inject({ url: '/api/admin/vms', headers: { cookie } })).json().vms.map((v: any) => v.id), [ids.vm]);
  assert.equal((await app.inject({ method: 'POST', url: '/api/admin/targets', headers: { cookie, origin }, payload: { vmId: ids.otherVm, name: 'Ajeno', repository: 'ajeno', container: 'ajeno', stack: 'backend' } })).statusCode, 403);
  assert.equal((await createJob(cookie)).statusCode, 403);
});

test('idempotencia concurrente no duplica solicitudes ni permite reutilizar otra carga', async () => {
  const cookie = await login('alice'); const key = randomUUID();
  const responses = await Promise.all(Array.from({ length: 5 }, () => createJob(cookie, ids.a, true, key)));
  assert.ok(responses.every(r => r.statusCode === 202));
  assert.equal(new Set(responses.map(r => r.json().id)).size, 1);
  assert.equal((await createJob(cookie, ids.a, false, key)).statusCode, 409);
  assert.equal((await pool.query('SELECT * FROM jobs')).rowCount, 1);
});

test('la revocación oculta resultados y cancela solicitudes pendientes', async () => {
  const alice = await login('alice'); const admin = await login('admin'); const bob = await login('bob');
  const id = (await createJob(alice)).json().id;
  assert.equal((await app.inject({ url: `/api/jobs/${id}`, headers: { cookie: bob } })).statusCode, 404);
  const revoked = await app.inject({ method: 'PUT', url: `/api/admin/targets/${ids.a}/grant`, headers: { cookie: admin, origin }, payload: { userId: ids.alice, canRead: false, canWrite: false } });
  assert.equal(revoked.statusCode, 200, revoked.body);
  assert.equal((await app.inject({ url: `/api/jobs/${id}`, headers: { cookie: alice } })).statusCode, 404);
  assert.equal((await pool.query('SELECT state FROM jobs WHERE id=$1', [id])).rows[0].state, 'cancelled');
});

test('varios trabajadores no reservan simultáneamente un mismo destino', async () => {
  const cookie = await login('alice'); await createJob(cookie); await createJob(cookie);
  const jobs = await Promise.all([claim(pool), claim(pool), claim(pool)]);
  assert.equal(jobs.filter(Boolean).length, 1);
  assert.equal((await pool.query("SELECT 1 FROM jobs WHERE state='queued'")).rowCount, 1);
  const job = jobs.find(Boolean)!;
  await finish(pool, job, 'succeeded', 'Resultado autorizado');
  assert.ok(await claim(pool));
});

test('una caída requiere conciliación y no permite otra ejecución del destino', async () => {
  const cookie = await login('alice'); await createJob(cookie); await createJob(cookie);
  const job = (await claim(pool))!;
  await pool.query("UPDATE jobs SET heartbeat_at=now()-interval '3 minutes' WHERE id=$1", [job.id]);
  await quarantineStale(pool);
  assert.equal(await claim(pool), null);
  await finish(pool, job, 'succeeded', 'Respuesta tardía');
  assert.equal((await pool.query('SELECT state FROM jobs WHERE id=$1', [job.id])).rows[0].state, 'reconciliation_required');
});

test('revocar durante la ejecución invalida el latido y no reporta éxito', async () => {
  const alice = await login('alice'); const admin = await login('admin'); await createJob(alice);
  const job = (await claim(pool))!;
  await app.inject({ method: 'PUT', url: `/api/admin/targets/${ids.a}/grant`, headers: { cookie: admin, origin }, payload: { userId: ids.alice, canRead: false, canWrite: false } });
  assert.equal(await heartbeat(pool, job), false);
  await finish(pool, job, 'succeeded', 'Resultado tardío');
  assert.equal((await pool.query('SELECT state FROM jobs WHERE id=$1', [job.id])).rows[0].state, 'reconciliation_required');
});

test('trabajador conserva solicitante y política de solo lectura', async () => {
  const cookie = await login('bob'); const id = (await createJob(cookie, ids.b)).json().id;
  await workOnce(pool, { async run(job) { assert.equal(job.user_id, ids.bob); assert.equal(job.read_only, true); assert.equal(job.container, 'pagos'); return { state: 'succeeded', result: 'Consulta completada' }; } });
  assert.equal((await app.inject({ url: `/api/jobs/${id}`, headers: { cookie } })).json().job.result, 'Consulta completada');
});

test('desactivar cuenta elimina sus sesiones', async () => {
  const alice = await login('alice'); const root = await login('root');
  await app.inject({ method: 'PATCH', url: `/api/admin/users/${ids.alice}`, headers: { cookie: root, origin }, payload: { active: false } });
  assert.equal((await app.inject({ url: '/api/me', headers: { cookie: alice } })).statusCode, 401);
});

test('límite de intentos de inicio de sesión persiste en PostgreSQL', async () => {
  for (let i = 0; i < 10; i++) assert.equal((await app.inject({ method: 'POST', url: '/api/login', headers: { origin }, payload: { email: 'no-existe@example.test', password: 'contraseña incorrecta' } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/api/login', headers: { origin }, payload: { email: 'no-existe@example.test', password: 'contraseña incorrecta' } })).statusCode, 429);
});

test('registro del ejecutor rechaza destinos sin aislamiento verificado', () => {
  assert.throws(() => validateConnection({} as any));
  const connection = { host: 'vm.example.test', user: 'orquestador', port: 22, identityFile: '/run/secrets/key', knownHostsFile: '/etc/known_hosts', container: 'pagos', repository: 'pagos', stack: 'backend', isolationVerified: true };
  validateConnection(connection);
  assert.throws(() => validateConnection({ ...connection, host: '-opcion' }));
  assert.throws(() => validateConnection({ ...connection, isolationVerified: false }));
});

test('un módulo recién registrado no puede ejecutarse hasta verificar el entorno', async () => {
  const cookie = await login('alice');
  await pool.query('UPDATE targets SET execution_ready=false WHERE id=$1', [ids.a]);
  assert.equal((await createJob(cookie)).statusCode, 409);
  assert.equal((await pool.query('SELECT 1 FROM jobs')).rowCount, 0);
});

test('administrador delegado consulta sus asignaciones y retira el módulo', async () => {
  const cookie = await login('admin');
  const grants = await app.inject({ url: `/api/admin/targets/${ids.a}/grants`, headers: { cookie } });
  assert.equal(grants.statusCode, 200);
  assert.equal(grants.json().grants[0].user_id, ids.alice);
  const alice = await login('alice'); const job = (await createJob(alice)).json().id;
  await app.inject({ method: 'PATCH', url: `/api/admin/targets/${ids.a}`, headers: { cookie, origin }, payload: { active: false } });
  assert.equal((await pool.query('SELECT state FROM jobs WHERE id=$1', [job])).rows[0].state, 'cancelled');
  assert.equal((await app.inject({ url: '/api/targets', headers: { cookie: alice } })).json().targets.length, 0);
});

test('un administrador delegado pierde el acceso al retirarle la asignación', async () => {
  const root = await login('root'); const admin = await login('admin');
  await app.inject({ method: 'DELETE', url: `/api/admin/vms/${ids.vm}/admin`, headers: { cookie: root, origin }, payload: { userId: ids.admin } });
  assert.equal((await app.inject({ url: `/api/admin/targets/${ids.a}/grants`, headers: { cookie: admin } })).statusCode, 403);
});

test('cambiar contraseña invalida todas las sesiones y la contraseña anterior', async () => {
  const cookie = await login('alice');
  const changed = await app.inject({ method: 'POST', url: '/api/me/password', headers: { cookie, origin }, payload: { currentPassword: password, password: 'Otra contraseña segura de pruebas' } });
  assert.equal(changed.statusCode, 200);
  assert.equal((await app.inject({ url: '/api/me', headers: { cookie } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/api/login', headers: { origin }, payload: { email: 'alice@example.test', password } })).statusCode, 401);
});

test('la sesión expirada no permite consultar datos', async () => {
  const cookie = await login('alice');
  await pool.query("UPDATE sessions SET expires_at=now()-interval '1 second'");
  assert.equal((await app.inject({ url: '/api/jobs', headers: { cookie } })).statusCode, 401);
});
