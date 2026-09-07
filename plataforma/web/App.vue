<script setup lang="ts">
import PreparationPanel from './PreparationPanel.vue';
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';

type User = { id: string; name: string; email: string; role: string; system_admin: boolean; active?: boolean };
type Target = { id: string; name: string; vm_id: string; vm_name?: string; repository: string; container: string; stack: string; active: boolean; execution_ready: boolean; can_write?: boolean };
type Job = { id: string; target_id: string; state: string; read_only: boolean; created_at: string; prompt?: string; result?: string };
const user = ref<User | null>(null);
const targets = ref<Target[]>([]), adminTargets = ref<Target[]>([]), users = ref<User[]>([]);
const vms = ref<{ id: string; name: string; active: boolean }[]>([]), jobs = ref<Job[]>([]);
const selectedJob = ref<Job | null>(null);
const grants = ref<{ user_id: string; name: string; email: string; can_read: boolean; can_write: boolean }[]>([]);
const section = ref('solicitudes'), booting = ref(true), busy = ref(false), error = ref(''), notice = ref('');
const credentials = reactive({ email: '', password: '' });
const request = reactive({ targetId: '', prompt: '', readOnly: true });
const newUser = reactive({ email: '', name: '', password: '', role: 'operator' });
const newTarget = reactive({ vmId: '', name: '', repository: '', container: '', stack: 'backend' });
const grant = reactive({ targetId: '', userId: '', canRead: true, canWrite: false });
const manager = reactive({ vmId: '', userId: '' });
const vmName = ref('');
const passwords = reactive({ currentPassword: '', password: '' });
const showPassword = ref(false);
const admin = computed(() => user.value?.role === 'admin');
const selectedTarget = computed(() => targets.value.find(t => t.id === request.targetId));
const labels: Record<string, string> = { queued: 'En cola', running: 'En ejecución', succeeded: 'Completada', failed: 'Fallida', cancel_requested: 'Cancelación pendiente', cancelled: 'Cancelada', reconciliation_required: 'Requiere revisión' };
const activeJobs = computed(() => jobs.value.filter(j => ['queued', 'running', 'cancel_requested'].includes(j.state)).length);
const date = (value: string) => new Intl.DateTimeFormat('es', { dateStyle: 'short', timeStyle: 'short' }).format(new Date(value));
const targetName = (id: string) => targets.value.find(t => t.id === id)?.name ?? 'Módulo asignado';
let epoch = 0;
let poll: ReturnType<typeof setInterval> | undefined;

function clearSession() {
  epoch++; user.value = null; targets.value = []; adminTargets.value = []; users.value = []; vms.value = []; jobs.value = []; grants.value = [];
  selectedJob.value = null; request.prompt = ''; request.targetId = ''; section.value = 'solicitudes';
}
async function api(path: string, method = 'GET', payload?: unknown) {
  const response = await fetch(`/api${path}`, { method, credentials: 'same-origin', headers: payload === undefined ? {} : { 'Content-Type': 'application/json' }, body: payload === undefined ? undefined : JSON.stringify(payload) });
  const result = await response.json();
  if (!response.ok) {
    if (response.status === 401 && path !== '/login') clearSession();
    throw new Error(result.error ?? 'No se pudo completar la operación.');
  }
  return result;
}
async function action(task: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true; error.value = ''; notice.value = '';
  try { await task(); } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function refresh() {
  const current = epoch;
  const [t, j] = await Promise.all([api('/targets'), api('/jobs')]);
  if (current !== epoch || !user.value) return;
  targets.value = t.targets; jobs.value = j.jobs;
  if (!targets.value.some(t => t.id === request.targetId)) request.targetId = targets.value.length === 1 ? targets.value[0].id : '';
  if (!selectedTarget.value?.can_write) request.readOnly = true;
  if (admin.value) {
    const [v, u, a] = await Promise.all([api('/admin/vms'), api('/admin/users'), api('/admin/targets')]);
    if (current !== epoch || !user.value) return;
    vms.value = v.vms; users.value = u.users; adminTargets.value = a.targets;
  }
}
async function signIn() {
  await action(async () => {
    const result = await api('/login', 'POST', credentials);
    credentials.password = ''; epoch++; user.value = result.user; await refresh();
  });
}
async function signOut() { await action(async () => { await api('/logout', 'POST'); clearSession(); }); }
async function submitRequest() {
  await action(async () => {
    if (!selectedTarget.value?.execution_ready) throw new Error('Selecciona un módulo preparado para ejecutar.');
    const job = await api('/jobs', 'POST', { ...request, idempotencyKey: crypto.randomUUID() });
    request.prompt = ''; notice.value = 'Solicitud recibida. Puedes seguir su estado en el historial.';
    await refresh(); selectedJob.value = (await api(`/jobs/${job.id}`)).job;
  });
}
async function showJob(id: string) { await action(async () => { selectedJob.value = (await api(`/jobs/${id}`)).job; }); }
async function loadGrants() { grants.value = grant.targetId ? (await api(`/admin/targets/${grant.targetId}/grants`)).grants : []; }
async function saveGrant() { await action(async () => { await api(`/admin/targets/${grant.targetId}/grant`, 'PUT', { userId: grant.userId, canRead: grant.canRead, canWrite: grant.canRead && grant.canWrite }); notice.value = 'Permisos actualizados.'; await loadGrants(); await refresh(); }); }
async function createUser() { await action(async () => { const result = await api('/admin/users', 'POST', newUser); newUser.password = ''; newUser.email = ''; newUser.name = ''; grant.userId = result.id; notice.value = 'Cuenta creada. Asigna sus módulos para habilitar el acceso.'; await refresh(); }); }
async function createTarget() { await action(async () => { await api('/admin/targets', 'POST', newTarget); notice.value = 'Módulo registrado. La ejecución se habilitará después de verificar el entorno remoto.'; newTarget.name = ''; newTarget.repository = ''; newTarget.container = ''; await refresh(); }); }
async function createVm() { await action(async () => { await api('/admin/vms', 'POST', { name: vmName.value }); vmName.value = ''; notice.value = 'Máquina registrada.'; await refresh(); }); }
async function assignManager(remove = false) { await action(async () => { await api(`/admin/vms/${manager.vmId}/admin`, remove ? 'DELETE' : 'PUT', { userId: manager.userId }); notice.value = remove ? 'Administración retirada.' : 'Administrador asignado.'; }); }
async function toggleUser(item: User) { if (!window.confirm(`${item.active ? 'Desactivar' : 'Activar'} la cuenta de ${item.name}?`)) return; await action(async () => { await api(`/admin/users/${item.id}`, 'PATCH', { active: !item.active }); await refresh(); }); }
async function toggleTarget(item: Target) { await action(async () => { await api(`/admin/targets/${item.id}`, 'PATCH', { active: !item.active }); await refresh(); }); }
async function cancelJob(job: Job) { await action(async () => { await api(`/jobs/${job.id}/cancel`, 'POST'); await refresh(); selectedJob.value = (await api(`/jobs/${job.id}`)).job; }); }
const matrixUserId = ref('');
const userGrantsMap = reactive<Record<string, { canRead: boolean; canWrite: boolean }>>({});

async function loadUserMatrix() {
  if (!matrixUserId.value) return;
  await action(async () => {
    const data = await api(`/admin/users/${matrixUserId.value}/permissions`);
    if (data.vms) vms.value = data.vms;
    if (data.targets) adminTargets.value = data.targets;
    for (const key of Object.keys(userGrantsMap)) delete userGrantsMap[key];
    for (const t of adminTargets.value) {
      const existing = data.grants.find((g: { target_id: string; can_read: boolean; can_write: boolean }) => g.target_id === t.id);
      userGrantsMap[t.id] = { canRead: existing?.can_read ?? false, canWrite: existing?.can_write ?? false };
    }
  });
}

async function saveUserMatrix() {
  if (!matrixUserId.value) return;
  await action(async () => {
    const payload = Object.entries(userGrantsMap).map(([targetId, perm]) => ({
      targetId,
      canRead: perm.canRead,
      canWrite: perm.canRead && perm.canWrite
    }));
    await api(`/admin/users/${matrixUserId.value}/permissions`, 'PUT', { grants: payload });
    notice.value = 'Permisos guardados correctamente y config/vms.json actualizado.';
    await refresh();
  });
}

async function changePassword() { await action(async () => { await api('/me/password', 'POST', passwords); passwords.currentPassword = ''; passwords.password = ''; clearSession(); notice.value = 'Contraseña actualizada. Inicia sesión de nuevo.'; }); }

const toolsLifecycle = new AbortController();
onMounted(async () => {
  try { user.value = (await api('/me')).user; await refresh(); } catch (e) { if (user.value) error.value = (e as Error).message; }
  finally { booting.value = false; }
  poll = setInterval(async () => { if (user.value && !busy.value) { try { await refresh(); if (selectedJob.value) selectedJob.value = (await api(`/jobs/${selectedJob.value.id}`)).job; } catch (e) { error.value = (e as Error).message; } } }, 15000);
  const context = (document as Document & { modelContext?: { registerTool: (tool: unknown, options: unknown) => unknown } }).modelContext;
  if (context?.registerTool) {
    try {
      await context.registerTool({ name: 'listar_modulos', title: 'Consultar módulos asignados', description: 'Lista los módulos autorizados de la sesión actual.', inputSchema: { type: 'object', properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true }, execute: async () => { if (!user.value) throw new Error('Inicia sesión.'); await refresh(); return targets.value.map(t => ({ id: t.id, name: t.name, ready: t.execution_ready, canWrite: t.can_write })); } }, { signal: toolsLifecycle.signal });
      await context.registerTool({ name: 'preparar_solicitud', title: 'Preparar una solicitud', description: 'Rellena el formulario para revisión del usuario; no envía ni ejecuta la solicitud.', inputSchema: { type: 'object', properties: { targetId: { type: 'string' }, prompt: { type: 'string', maxLength: 20000 } }, required: ['targetId', 'prompt'], additionalProperties: false }, annotations: { readOnlyHint: false }, execute: async (input: unknown) => {
        const i = input as { targetId?: unknown; prompt?: unknown };
        if (!i || typeof i.targetId !== 'string' || typeof i.prompt !== 'string' || !i.prompt.trim() || i.prompt.length > 20000 || Object.keys(i).some(k => !['targetId', 'prompt'].includes(k))) throw new Error('Datos inválidos.');
        if (!user.value) throw new Error('Inicia sesión.'); await refresh();
        if (!targets.value.some(t => t.id === i.targetId && t.execution_ready)) throw new Error('Destino no disponible.');
        request.targetId = i.targetId; request.prompt = i.prompt; request.readOnly = true; section.value = 'solicitudes'; return { prepared: true, submitted: false };
      } }, { signal: toolsLifecycle.signal });
    } catch { /* La aplicación funciona también sin soporte WebMCP. */ }
  }
});
onUnmounted(() => { if (poll) clearInterval(poll); toolsLifecycle.abort(); });
</script>

<template>
  <div v-if="booting" class="loading" role="status">Abriendo tu espacio de trabajo…</div>
  <main v-else-if="!user" class="login-layout">
    <section class="login-intro"><div class="brand"><span class="brand-symbol">◈</span> orquestador<span class="version">PLATAFORMA</span></div><div><p class="eyebrow">TU EQUIPO DE AGENTES</p><h1>Un lugar para<br>coordinar el trabajo.</h1><p class="intro-copy">Envía solicitudes a tus módulos, sigue cada ejecución y mantén el control de los accesos.</p><div class="flow"><span>Tu solicitud</span><span>→</span><span>Tu módulo</span><span>→</span><span>Resultados</span></div></div><p class="intro-footer">Acceso por usuario · Ejecución por módulo</p></section>
    <section class="login-form"><form @submit.prevent="signIn"><p class="eyebrow">BIENVENIDO</p><h2>Inicia sesión</h2><p class="muted">Accede con la cuenta asignada por tu administrador.</p><p v-if="error" role="alert" class="alert error">{{ error }}</p><p v-if="notice" role="status" class="alert">{{ notice }}</p><label>Correo electrónico<input v-model="credentials.email" type="email" autocomplete="username" required placeholder="nombre@empresa.com" maxlength="254"></label><label>Contraseña<input v-model="credentials.password" type="password" autocomplete="current-password" required maxlength="256"></label><button class="primary" :disabled="busy">{{ busy ? 'Verificando…' : 'Entrar al espacio de trabajo' }} <span>→</span></button><p class="hint">Si aún no tienes una cuenta, solicítala al administrador de la plataforma.</p></form></section>
  </main>
  <div v-else class="workspace">
    <aside class="sidebar"><div class="brand"><span class="brand-symbol">◈</span> orquestador</div><p class="nav-label">ESPACIO DE TRABAJO</p><nav aria-label="Principal"><button :class="{ selected: section === 'solicitudes' }" @click="section = 'solicitudes'">↗ <span>Solicitudes</span></button><button v-if="admin" :class="{ selected: section === 'modulos' }" @click="section = 'modulos'">▦ <span>Módulos y permisos</span></button><button v-if="admin" :class="{ selected: section === 'usuarios' }" @click="section = 'usuarios'">◎ <span>Usuarios</span></button><button v-if="admin" :class="{ selected: section === 'maquinas' }" @click="section = 'maquinas'">▤ <span>Máquinas virtuales</span></button></nav><div class="sidebar-bottom"><div class="avatar">{{ user.name.slice(0, 1).toUpperCase() }}</div><strong>{{ user.name }}</strong><small>{{ user.system_admin ? 'Administrador general' : admin ? 'Administrador' : 'Operador' }}</small><button @click="showPassword = !showPassword">Cambiar contraseña</button><button @click="signOut" :disabled="busy">Cerrar sesión ↗</button></div></aside>
    <main class="main"><header class="topbar"><span>PLATAFORMA / {{ section.toUpperCase() }}</span><span class="session-indicator">Sesión activa</span></header>
      <div class="content"><p v-if="error" class="alert error" role="alert">{{ error }}</p><p v-if="notice" class="alert" role="status">{{ notice }}</p>
        <form v-if="showPassword" class="panel compact-form" @submit.prevent="changePassword"><h2>Cambiar contraseña</h2><label>Contraseña actual<input v-model="passwords.currentPassword" type="password" autocomplete="current-password" required></label><label>Nueva contraseña<input v-model="passwords.password" type="password" autocomplete="new-password" minlength="12" maxlength="256" required></label><button class="primary" :disabled="busy">Guardar y cerrar sesión</button><button type="button" @click="showPassword = false">Cerrar</button></form>
        <template v-if="section === 'solicitudes'"><div class="page-title"><div><p class="eyebrow">SOLICITUDES</p><h1>Tu espacio de trabajo</h1><p class="muted">Describe el objetivo. El agente trabajará en el módulo que selecciones.</p></div><button class="secondary" @click="action(refresh)" :disabled="busy">Actualizar ↻</button></div>
          <div class="stats"><div><span>Módulos asignados</span><strong>{{ targets.length }}</strong></div><div><span>Solicitudes activas</span><strong>{{ activeJobs }}</strong></div><div><span>Completadas en el historial</span><strong>{{ jobs.filter(j => j.state === 'succeeded').length }}</strong></div></div>
          <div class="request-grid"><form class="panel" @submit.prevent="submitRequest"><div class="panel-heading"><h2>Nueva solicitud</h2><span class="pill">Analista LLM + Agentes</span></div><label>Destino o ámbito<select v-model="request.targetId" required @change="request.readOnly = true"><option value="auto">✨ Análisis y enrutamiento automático (Hermes 3 · Todos mis módulos)</option><option v-for="t in targets" :key="t.id" :value="t.id">{{ t.name }} · {{ t.vm_name }}{{ t.execution_ready ? '' : ' · En preparación' }}</option></select></label><p v-if="selectedTarget" class="context-line">{{ selectedTarget.vm_name }} <span> / </span> {{ selectedTarget.name }}</p><p v-else class="context-line">Hermes 3 analizará el prompt y asignará sub-tareas a tus módulos autorizados</p><label>¿Qué necesitas hacer?<textarea v-model="request.prompt" rows="7" required maxlength="20000" placeholder="Por ejemplo: agrega un endpoint de comentarios en backend y su vista/componente en Vue."></textarea></label><div class="request-options"><label class="checkbox"><input v-model="request.readOnly" type="checkbox" :disabled="selectedTarget && !selectedTarget.can_write"> Solo lectura</label><small>{{ request.prompt.length.toLocaleString('es') }} / 20.000</small></div><p class="hint">{{ request.readOnly ? 'El agente podrá analizar los módulos sin modificar su código.' : 'El agente podrá preparar cambios en una copia independiente.' }}</p><p v-if="selectedTarget && !selectedTarget.execution_ready" class="alert">Este módulo está pendiente de preparación por el administrador.</p><button class="primary" :disabled="busy || (selectedTarget && !selectedTarget.execution_ready) || !request.prompt.trim()">Enviar solicitud <span>↗</span></button></form>
            <section class="panel destinations"><h2>Tus módulos</h2><p class="muted">Solo aparecen los destinos que tienes asignados.</p><div v-if="!targets.length" class="empty"><span>▦</span><h3>Aún no tienes módulos</h3><p>Tu administrador debe asignarte un destino para empezar.</p></div><button v-for="t in targets" :key="t.id" class="destination" type="button" @click="request.targetId = t.id; request.readOnly = true"><div><strong>{{ t.name }}</strong><small>{{ t.vm_name }}</small></div><span class="pill" :class="{ pending: !t.execution_ready }">{{ t.execution_ready ? (t.can_write ? 'Lectura y cambios' : 'Lectura') : 'En preparación' }}</span></button></section></div>
          <section class="panel history"><div class="panel-heading"><h2>Historial de solicitudes</h2><small>Últimas 100 solicitudes</small></div><div v-if="!jobs.length" class="empty"><h3>Tu primera solicitud empieza aquí</h3><p>Cuando envíes una tarea, podrás seguir su estado y consultar el resultado.</p></div><div v-else class="table-wrap"><table><thead><tr><th>Módulo</th><th>Modalidad</th><th>Estado</th><th>Fecha</th><th></th></tr></thead><tbody><tr v-for="j in jobs" :key="j.id"><td>{{ targetName(j.target_id) }}</td><td>{{ j.read_only ? 'Solo lectura' : 'Preparar cambios' }}</td><td><span class="pill" :class="j.state">{{ labels[j.state] }}</span></td><td>{{ date(j.created_at) }}</td><td><button class="text-button" @click="showJob(j.id)">Ver detalle →</button></td></tr></tbody></table></div></section>
          <section v-if="selectedJob" class="panel job-detail"><div class="panel-heading"><h2>Detalle de la solicitud</h2><button @click="selectedJob = null">Cerrar ×</button></div><p><span class="pill" :class="selectedJob.state">{{ labels[selectedJob.state] }}</span></p><h3>Objetivo</h3><pre>{{ selectedJob.prompt }}</pre><h3>Resultado</h3><pre>{{ selectedJob.result || 'El resultado estará disponible cuando termine la ejecución.' }}</pre><button v-if="['queued', 'running'].includes(selectedJob.state)" class="secondary" :disabled="busy" @click="cancelJob(selectedJob)">Solicitar cancelación</button></section>
        </template>
        <template v-if="section === 'modulos' && admin"><PreparationPanel kind="targets" :global-admin="user.system_admin" :items="adminTargets" :api="api" @changed="action(refresh)" /><div class="page-title"><div><p class="eyebrow">ADMINISTRACIÓN</p><h1>Módulos y permisos</h1><p class="muted">Define los permisos por usuario marcando los módulos y VMs autorizadas.</p></div></div><form class="panel full-width" @submit.prevent="saveUserMatrix"><h2>Matriz Visual de Permisos por Usuario (config/vms.json)</h2><p class="muted">Selecciona un usuario y marca los checkboxes de lectura y escritura para sus VMs y módulos. Los cambios actualizarán la cola y <code>config/vms.json</code>.</p><label>Usuario a administrar<select v-model="matrixUserId" required @change="loadUserMatrix"><option disabled value="">Selecciona un usuario</option><option v-for="u in users" :key="u.id" :value="u.id">{{ u.name }} · {{ u.email }} ({{ u.role === 'admin' ? 'Administrador' : 'Operador' }})</option></select></label><div v-if="matrixUserId" class="vms-permissions-grid"><div v-for="v in vms" :key="v.id" class="vm-card"><div class="vm-card-header"><strong>🖥️ VM: {{ v.name }}</strong></div><div class="vm-card-modules"><div v-for="t in adminTargets.filter(t => t.vm_id === v.id)" :key="t.id" class="module-perm-item"><div class="module-title"><strong>{{ t.name }}</strong><small>{{ t.repository }} · {{ t.container }} ({{ t.stack }})</small></div><div v-if="userGrantsMap[t.id]" class="checkbox-group"><label class="checkbox"><input type="checkbox" v-model="userGrantsMap[t.id].canRead" @change="!userGrantsMap[t.id].canRead && (userGrantsMap[t.id].canWrite = false)"> Lectura</label><label class="checkbox"><input type="checkbox" v-model="userGrantsMap[t.id].canWrite" :disabled="!userGrantsMap[t.id].canRead"> Escritura</label></div></div><div v-if="!adminTargets.some(t => t.vm_id === v.id)" class="empty-sub">Sin módulos asociados en esta VM</div></div></div></div><button v-if="matrixUserId" class="primary" :disabled="busy">Guardar Permisos y Sincronizar config/vms.json 💾</button></form><div class="two-columns"><form class="panel" @submit.prevent="createTarget"><h2>Registrar módulo</h2><label>Máquina virtual<select v-model="newTarget.vmId" required><option disabled value="">Selecciona una máquina</option><option v-for="v in vms" :value="v.id">{{ v.name }}</option></select></label><label>Nombre visible<input v-model="newTarget.name" required maxlength="100" placeholder="Comentarios"></label><label>Repositorio<input v-model="newTarget.repository" pattern="[a-zA-Z0-9][a-zA-Z0-9._-]*" required placeholder="comments"></label><label>Contenedor de Podman<input v-model="newTarget.container" pattern="[a-zA-Z0-9][a-zA-Z0-9._-]*" required placeholder="modulo-comments"></label><label>Especialidad<select v-model="newTarget.stack"><option value="backend">Backend</option><option value="frontend">Frontend</option></select></label><button class="primary" :disabled="busy || !vms.length">Registrar módulo</button></form><form class="panel" @submit.prevent="saveGrant"><h2>Asignación rápida por módulo</h2><label>Módulo<select v-model="grant.targetId" required @change="action(loadGrants)"><option disabled value="">Selecciona un módulo</option><option v-for="t in adminTargets" :value="t.id">{{ t.name }}</option></select></label><label>Usuario<select v-model="grant.userId" required><option disabled value="">Selecciona una persona</option><option v-for="u in users" :value="u.id">{{ u.name }} · {{ u.email }}</option></select></label><label class="checkbox"><input v-model="grant.canRead" type="checkbox" @change="!grant.canRead && (grant.canWrite = false)"> Consultar y ejecutar en solo lectura</label><label class="checkbox"><input v-model="grant.canWrite" type="checkbox" :disabled="!grant.canRead"> Preparar cambios en el código</label><button class="primary" :disabled="busy">Guardar permiso rápido</button><h3 v-if="grants.length">Asignaciones actuales del módulo</h3><div v-for="g in grants" class="grant-row"><div><strong>{{ g.name }}</strong><small>{{ g.can_write ? 'Lectura y cambios' : g.can_read ? 'Solo lectura' : 'Sin acceso' }}</small></div><button type="button" class="text-button" @click="grant.userId = g.user_id; grant.canRead = g.can_read; grant.canWrite = g.can_write">Editar</button></div></form></div><section class="panel"><h2>Módulos registrados</h2><div v-if="!adminTargets.length" class="empty">Registra el primer módulo para comenzar.</div><div v-for="t in adminTargets" class="destination"><div><strong>{{ t.name }}</strong><small>{{ t.repository }} · {{ t.container }}</small></div><span class="pill">{{ !t.active ? 'Desactivado' : t.execution_ready ? 'Preparado' : 'Preparación pendiente' }}</span><button class="text-button" :disabled="busy" @click="toggleTarget(t)">{{ t.active ? 'Desactivar' : 'Activar' }}</button></div></section></template>
        <template v-if="section === 'usuarios' && admin"><div class="page-title"><div><p class="eyebrow">ADMINISTRACIÓN</p><h1>Usuarios</h1><p class="muted">Crea cuentas y asigna el acceso desde Módulos y permisos.</p></div></div><div class="two-columns"><form class="panel" @submit.prevent="createUser"><h2>Nueva cuenta</h2><label>Nombre<input v-model="newUser.name" required maxlength="100"></label><label>Correo<input v-model="newUser.email" type="email" required maxlength="254" autocomplete="off"></label><label>Contraseña inicial<input v-model="newUser.password" type="password" required minlength="12" maxlength="256" autocomplete="new-password"></label><p class="hint">Mínimo 12 caracteres. La persona podrá cambiarla al iniciar sesión.</p><label>Rol<select v-model="newUser.role"><option value="operator">Operador</option><option v-if="user.system_admin" value="admin">Administrador</option></select></label><button class="primary" :disabled="busy">Crear cuenta</button></form><section class="panel"><h2>Cuentas de tu ámbito</h2><div v-for="u in users" :key="u.id" class="destination"><div><strong>{{ u.name }}</strong><small>{{ u.email }}</small><small>{{ u.role === 'admin' ? 'Administrador' : 'Operador' }} · {{ u.active ? 'Activa' : 'Desactivada' }}</small></div><button v-if="user.system_admin && u.id !== user.id" class="text-button" :disabled="busy" @click="toggleUser(u)">{{ u.active ? 'Desactivar' : 'Activar' }}</button></div></section></div></template>
        <template v-if="section === 'maquinas' && admin"><PreparationPanel kind="vms" :global-admin="user.system_admin" :items="vms" :api="api" @changed="action(refresh)" /><div class="page-title"><div><p class="eyebrow">INFRAESTRUCTURA ASIGNADA</p><h1>Máquinas virtuales</h1><p class="muted">Administra los destinos disponibles para tu equipo.</p></div></div><div class="two-columns"><section class="panel"><h2>Máquinas de tu ámbito</h2><div v-if="!vms.length" class="empty">Todavía no hay máquinas asignadas.</div><div v-for="v in vms" :key="v.id" class="destination"><strong>{{ v.name }}</strong><span class="pill">{{ v.active ? 'Registrada' : 'Desactivada' }}</span></div><form v-if="user.system_admin" @submit.prevent="createVm"><label>Nombre de la nueva máquina<input v-model="vmName" required maxlength="100" placeholder="Desarrollo backend"></label><button class="primary" :disabled="busy">Registrar máquina</button></form></section><form v-if="user.system_admin" class="panel" @submit.prevent="assignManager()"><h2>Asignar administración</h2><label>Máquina<select v-model="manager.vmId" required><option disabled value="">Selecciona una máquina</option><option v-for="v in vms" :value="v.id">{{ v.name }}</option></select></label><label>Administrador<select v-model="manager.userId" required><option disabled value="">Selecciona una persona</option><option v-for="u in users.filter(u => u.role === 'admin' && u.active)" :value="u.id">{{ u.name }}</option></select></label><p class="hint">Podrá gestionar módulos y asignaciones dentro de esta máquina.</p><button class="primary" :disabled="busy">Asignar administrador</button><button type="button" class="secondary" :disabled="busy || !manager.vmId || !manager.userId" @click="assignManager(true)">Retirar administración</button></form></div></template>
      </div><footer>Orquestador · Accesos definidos por módulo</footer>
    </main>
  </div>
</template>
