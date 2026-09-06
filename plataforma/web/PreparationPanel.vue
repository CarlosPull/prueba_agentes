<script setup lang="ts">
import { onMounted, onUnmounted, reactive, ref } from 'vue';
const props = defineProps<{ kind: 'vms' | 'targets'; globalAdmin: boolean; items: { id: string; name: string }[]; api: (path:string,method?:string,payload?:unknown)=>Promise<any> }>();
const emit = defineEmits<{ changed: [] }>();
const selected=ref(''), busy=ref(false), error=ref(''), message=ref(''), publicKey=ref('');
const connection=reactive({host:'',port:22,fingerprint:''});
const source=reactive({gitUrl:'',branch:'main',credentialProfile:'piloto'});
const state=ref<any>({connections:[],sources:[],preparations:[],services:[]});
const labels: Record<string,string>={pending:'Pendiente',queued:'En cola',preparing:'Preparando',ready:'Preparado',failed:'Error',review:'Revisión necesaria',running:'En ejecución',succeeded:'Completado'};
let timer: ReturnType<typeof setInterval> | undefined;
let alive=true;
async function refresh(){ const result=await props.api('/admin/preparations'); if(alive) state.value=result; }
async function act(fn:()=>Promise<void>){if(busy.value)return;busy.value=true;error.value='';message.value='';try{await fn();await refresh();emit('changed');}catch(e){error.value=(e as Error).message;}finally{busy.value=false;}}
function choose(){const current=state.value.connections.find((v:any)=>v.vm_id===selected.value);if(current) Object.assign(connection,{host:current.host,port:current.port,fingerprint:current.host_fingerprint});const currentSource=state.value.sources.find((v:any)=>v.target_id===selected.value);if(currentSource)Object.assign(source,{gitUrl:currentSource.git_url,branch:currentSource.git_branch,credentialProfile:currentSource.credential_profile});}
async function save(){await act(async()=>{await props.api(`/admin/${props.kind}/${selected.value}/${props.kind==='vms'?'connection':'source'}`,'PUT',props.kind==='vms'?connection:source);message.value='Configuración guardada. Puedes solicitar la preparación.';});}
async function prepare(){await act(async()=>{await props.api(`/admin/${props.kind}/${selected.value}/prepare`,'POST');message.value='Preparación en cola. El módulo solo se habilitará si las verificaciones terminan correctamente.';});}
onMounted(async()=>{try{await refresh();if(props.globalAdmin){const result=await props.api('/admin/preparation/setup');if(alive) publicKey.value=result.publicKey;}}catch(e){error.value=(e as Error).message;}timer=setInterval(()=>{void refresh().catch(()=>{});},5000);});
onUnmounted(()=>{alive=false;if(timer)clearInterval(timer);});
</script>
<template>
<section class="panel">
  <h2>{{ kind==='vms'?'Conectar y preparar una VM':'Preparar el repositorio del módulo' }}</h2>
  <p class="muted">{{ kind==='vms'?'La VM debe existir. Instala primero la llave pública de preparación desde su consola.':'El módulo tendrá un contenedor y un volumen exclusivos. La preparación conserva los repositorios existentes.' }}</p>
  <p v-if="error" class="alert error" role="alert">{{ error }}</p><p v-if="message" class="alert" role="status">{{ message }}</p>
  <div class="context-line" v-for="s in state.services" :key="s.name">Servicio {{ s.name }}: {{ s.available?'disponible':'sin contacto' }}</div>
  <p v-if="!state.services.some((s:any)=>s.name==='preparacion' && s.available)" class="alert">El servicio de preparación no está disponible. Inicia los servicios del servidor antes de solicitar tareas.</p>
  <details v-if="kind==='vms' && globalAdmin"><summary>Preparar acceso por llave</summary><p>En la consola de la VM, añade esta llave pública a /root/.ssh/authorized_keys (directorio con permisos 700 y archivo 600). No reemplaces las llaves existentes. La cuenta root solo se utiliza para instalar el entorno; los módulos ejecutan como usuario de servicio.</p><textarea :value="publicKey || 'La llave aún no fue generada. Ejecuta el arranque del servidor.'" readonly rows="3" aria-label="Llave pública de preparación"></textarea><p>Obtén la huella del servidor en la consola de la VM:</p><pre>ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</pre><p>Copia únicamente el valor que comienza con SHA256. No introduzcas contraseñas ni claves privadas en estos formularios.</p></details>
  <form @submit.prevent="save">
    <label>{{ kind==='vms'?'Máquina virtual':'Módulo' }}<select v-model="selected" required @change="choose"><option value="" disabled>Selecciona un destino</option><option v-for="i in items" :key="i.id" :value="i.id">{{ i.name }}</option></select></label>
    <p v-if="selected" class="hint">Identificador: {{ selected }}</p>
    <template v-if="kind==='vms'"><label>IP o nombre del servidor<input v-model="connection.host" required maxlength="253" placeholder="192.168.1.119" :disabled="!globalAdmin"></label><label>Puerto SSH<input v-model.number="connection.port" type="number" min="1" max="65535" required :disabled="!globalAdmin"></label><label>Huella SSH ED25519<input v-model="connection.fingerprint" required placeholder="SHA256:…" :disabled="!globalAdmin"></label></template>
    <template v-else><label>URL HTTPS del repositorio Git<input v-model="source.gitUrl" type="url" required maxlength="1000" placeholder="https://github.com/organizacion/repositorio.git"></label><label>Rama base<input v-model="source.branch" required maxlength="160"></label><label>Perfil de credenciales autorizado<input v-model="source.credentialProfile" required pattern="[a-z][a-z0-9_-]*" maxlength="64"></label><p class="hint">El administrador del servidor instala el perfil con credenciales Pi y, si es necesario, acceso de lectura a Git. Las claves no se envían al navegador.</p></template>
    <button class="primary" :disabled="busy || !selected || (kind==='vms' && !globalAdmin)">Guardar configuración</button>
    <button type="button" class="secondary" :disabled="busy || !selected || (kind==='vms' && !globalAdmin)" @click="prepare">Preparar y verificar</button>
  </form>
  <h3>Estado de preparación</h3>
  <div v-for="p in state.preparations.filter((p:any)=>kind==='vms'?p.vm_id===selected: p.target_id===selected)" :key="p.id" class="grant-row"><div><strong>{{ labels[p.state] || p.state }}</strong><small>{{ p.stage }}</small></div></div>
  <p class="hint">Un error permite corregir la causa y volver a preparar. Si se perdió contacto, se requiere revisión administrativa del remoto antes de reintentar.</p>
</section>
</template>
