# 🚀 Guía Completa de Configuración y Provisionamiento

Esta guía describe paso a paso cómo preparar tu equipo local (Mac Orquestadora) y provisionar Servidores/VMs remotas para la ejecución del orquestador distribuido con **Pi** y el **Memory Gateway (mTLS)**.

---

## 📌 Requisitos Previos en la Mac Orquestadora

Antes de comenzar, asegúrate de tener instalados los siguientes componentes en tu máquina local:

- **OS**: macOS (o Linux para el rol orquestador).
- **Node.js**: `v24.0.0` o superior (`node -v`).
- **Python**: `3.10` o superior (`python3 --version`).
- **Herramientas CLI básicas**: `jq`, `ssh`, `rsync`, `curl`, `git`.
  ```bash
  brew install jq rsync node python
  ```
- **Ollama** (para la memoria contextual semántica de Cognee):
  ```bash
  ollama pull hermes3:latest
  ```

---

## 🔑 Paso 1: Configuración de Llaves SSH y GitHub

El sistema automatiza el acceso remoto por SSH a las VMs y el clonado de repositorios privados de GitHub.

### 1. Generar tu llave SSH local (si aún no tienes una)
```bash
ssh-keygen -t ed25519 -C "tu_email@ejemplo.com"
```
*(Acepta la ruta predeterminada `~/.ssh/id_ed25519`).*

### 2. Registrar tu llave SSH en GitHub
Copia tu clave pública:
```bash
cat ~/.ssh/id_ed25519.pub
```
Agrégala en GitHub: **Settings -> SSH and GPG keys -> New SSH key**.

Verifica la conexión con GitHub:
```bash
ssh -T git@github.com
```
Debe responder: `Hi username! You've successfully authenticated...`

---

## 💻 Paso 2: Clonar el Proyecto e Inicializar `.private/`

La carpeta `.private/` almacena certificados mTLS, base de datos local y memorias privadas sin ser subida a Git.

```bash
# 1. Entrar a la raíz del proyecto
cd prueba_agentes

# 2. Crear el entorno virtual e instalar dependencias de Cognee (memoria semántica)
python3 -m venv .private/cognee-venv
.private/cognee-venv/bin/pip install --upgrade pip
.private/cognee-venv/bin/pip install cognee uvicorn fastembed

# 3. Generar la PKI local mTLS para el Memory Gateway
./memory-gateway/bin/generar_pki.sh .private/memory-gateway-pki 127.0.0.1 backend frontend orchestrator-analyst memory-admin
cp .private/memory-gateway-pki/server.key .private/memory-gateway-pki/server-local.key
cp .private/memory-gateway-pki/server.crt .private/memory-gateway-pki/server-local.crt

# 4. Crear carpetas de datos e inventarios iniciales
mkdir -p .private/memory-gateway-data .private/memory-gateway-data/openapi
cp memory-gateway/config/clients.example.json .private/memory-gateway-clients.json
cp memoria/tecnologias.example.json .private/tecnologias.json
```

---

## 🧠 Paso 3: Levantar los Servicios Locales de Memoria

Abre dos terminales adicionales en la Mac para mantener activos los servicios de memoria durante el desarrollo:

### Terminal 1: Servidor Cognee (Grafo de Conocimiento)
```bash
PROJECT_ROOT="$PWD"

env \
  SYSTEM_ROOT_DIRECTORY="$PROJECT_ROOT/.private/cognee-system" \
  DATA_ROOT_DIRECTORY="$PROJECT_ROOT/.private/cognee-data" \
  COGNEE_LOGS_DIR="$PROJECT_ROOT/.private/cognee-logs" \
  REQUIRE_AUTHENTICATION=false \
  ENABLE_BACKEND_ACCESS_CONTROL=false \
  VECTOR_DB_PROVIDER=lancedb \
  LLM_PROVIDER=ollama \
  LLM_MODEL=hermes3:latest \
  LLM_ENDPOINT=http://127.0.0.1:11434 \
  EMBEDDING_PROVIDER=fastembed \
  EMBEDDING_MODEL=BAAI/bge-small-en-v1.5 \
  .private/cognee-venv/bin/python -m uvicorn cognee.api.v1.server.app:app --host 127.0.0.1 --port 8000
```

### Terminal 2: Memory Gateway mTLS
```bash
env \
  MEMORY_GATEWAY_HOST=0.0.0.0 \
  MEMORY_GATEWAY_PORT=9443 \
  MEMORY_GATEWAY_DB="$PWD/.private/memory-gateway-data/gateway.sqlite" \
  MEMORY_GATEWAY_CLIENTS="$PWD/.private/memory-gateway-clients.json" \
  MEMORY_GATEWAY_OPENAPI_DIR="$PWD/.private/memory-gateway-data/openapi" \
  MEMORY_GATEWAY_TLS_KEY="$PWD/.private/memory-gateway-pki/server-local.key" \
  MEMORY_GATEWAY_TLS_CERT="$PWD/.private/memory-gateway-pki/server-local.crt" \
  MEMORY_GATEWAY_TLS_CA="$PWD/.private/memory-gateway-pki/ca.crt" \
  COGNEE_BASE_URL=http://127.0.0.1:8000 \
  node memory-gateway/bin/memory-gateway.mjs
```

---

## ⚙️ Paso 4: Provisionamiento de VMs Remotas (SSH Automático + Pi)

El script `./tools/vms/provisionar_vm_pi.sh` se encarga de todo el flujo automático:
1. Copia tu llave SSH pública a la VM (`ssh-copy-id`) para habilitar acceso sin contraseña.
2. Comprueba tu autenticación con GitHub.
3. Instala paquetes base en la VM (`bubblewrap`, `PHP 8.4`, `cron`, `curl`, `rsync`, etc.).
4. Instala `Node 24`, `Pi` (`@at-wat/pi`) y `pi-harness` aislado en la VM.
5. Clona el repositorio del proyecto en la VM.
6. Instala el cron de sincronización automática de agentes (cada 30 seg).
7. Sincroniza las credenciales mTLS para el Memory Gateway.

### Comandos de Provisionamiento:

#### Opción A: Crear un nuevo perfil e instalar la VM por primera vez
```bash
# (Opcional) Si la VM clonará repositorios privados de GitHub:
export GITHUB_TOKEN='tu_github_token'

# Ejecutar el provisionador interactivo
./tools/vms/provisionar_vm_pi.sh <nombre-de-perfil> --con-sudo-interactivo
```
*El script detectará que el perfil no existe, te pedirá la IP, usuario, proyecto, stack (backend/frontend) y configurará `config/vms.json` automáticamente.*

#### Opción B: Si la llave SSH fallara por red (SSH Manual previo)
Si prefieres asegurar la copia SSH antes de provisionar:
```bash
./tools/vms/configurar_ssh_vm.sh usuario@ip_de_la_vm
```

---

## 🔍 Paso 5: Verificación del Entorno y Diagnóstico

Una vez completado el provisionamiento, valida la salud de la infraestructura:

### 1. Diagnóstico SSH y Conectividad de VMs
```bash
./tools/vms/probar_vms.sh
```

### 2. Auditar la instalación de Pi y pi-harness en una VM sin hacer cambios
```bash
./tools/vms/provisionar_vm_pi.sh <nombre-de-perfil> --solo-verificar
```

### 3. Sincronizar credenciales mTLS manualmente (si fuera necesario)
```bash
./tools/vms/sincronizar_mtls_vm.sh <nombre-de-perfil>
```

---

## 🚀 Paso 6: Ejecución de Tareas con el Orquestador

Para enviar objetivos al sistema distribuido de agentes:

```bash
# Descomponer los requisitos en JSON (sin ejecutar)
./tools/orquestacion/orquestar.sh --descomponer "Crear endpoint de autenticación JWT y vista de Login"

# Clasificar la tarea (Backend / Frontend / Fullstack)
./tools/orquestacion/orquestar.sh --clasificar "Crear endpoint de autenticación JWT"

# Ejecutar la orquestación completa
./tools/orquestacion/orquestar.sh "Crear endpoint de autenticación JWT y vista de Login"
```

---

## 📊 Visualizador de Grafos de Memoria (Opcional)

Puedes visualizar el grafo semántico de decisiones y contratos mediante el Gateway en tu navegador:

```bash
python3 tools/gateway/visualizar_grafos.py --abrir
```

---

## 🛠️ Resumen de Scripts Útiles (`tools/`)

| Script | Descripción |
| :--- | :--- |
| `./tools/vms/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo` | Provisiona una VM remota de principio a fin. |
| `./tools/vms/provisionar_vm_pi.sh <perfil> --solo-configurar` | Crea/modifica el perfil en `vms.json` sin conectarse a la VM. |
| `./tools/vms/provisionar_vm_pi.sh <perfil> --solo-verificar` | Audita la instalación de Pi/harness sin reinstallar nada. |
| `./tools/vms/probar_vms.sh` | Comprueba SSH a todas las VMs declaradas en `vms.json`. |
| `./tools/vms/configurar_ssh_vm.sh user@ip` | Copia la clave SSH local a la VM objetivo. |
| `./tools/orquestacion/orquestar.sh "objetivo"` | Inicia la orquestación y despacho distribuido. |
