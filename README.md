# Orquestador distribuido de agentes con Pi y memoria compartida

Este repositorio contiene un orquestador local escrito en shell script. Recibe un prompt libre, recopila contexto de memoria, lo divide en requisitos atómicos, selecciona la VM y el repositorio correctos y ejecuta cada subtarea mediante **Pi** y `pi-harness` dentro de la VM. La Mac no ejecuta Pi ni modifica directamente los repositorios remotos.

> El flujo anterior basado en Python, OpenCode o `agent-runner` fue retirado. El motor de ejecución actual es exclusivamente Pi.

## Flujo completo

```mermaid
flowchart TD
    U["Prompt general"] --> C["Recolector de contexto"]
    U --> D["División inicial en<br/>requisitos pequeños"]

    INV["Inventario de módulos y VMs"] --> C
    TEC["Tecnología privada de la empresa"] --> C
    C -- "Busca memoria company<br/>y contratos compartidos" --> GW

    subgraph MEM["Memoria central"]
        GW["Memory Gateway<br/>mTLS + permisos"]
        GW --> COG["Cognee<br/>búsqueda semántica"]
        GW --> SQL["SQLite + OpenAPI<br/>fuente autoritativa"]
        SQL -- "indexa" --> COG
        COG -. "fallback" .-> SQL
    end

    GW -- "Memoria relevante" --> CTX["Contexto completo"]
    C -- "Prompt + inventario<br/>+ tecnología" --> CTX
    CTX --> A["Analista central"]
    D --> A
    A --> RQ["Asigna los requisitos<br/>a los módulos correctos"]
    RQ --> P["Despacho paralelo<br/>a las VMs seleccionadas"]

    subgraph VMS["Cada VM"]
        P --> H["Pi + agente especializado"]
        BM["Memoria de negocio<br/>local del módulo"] --> H
        H --> W["Trabaja únicamente en<br/>su repositorio autorizado"]
    end

    H -- "Consulta o publica contratos" --> GW
    W --> R["Reporte y evidencia final"]
```

El recolector obtiene el inventario, la tecnología privada, la memoria `company` y los contratos compartidos. En paralelo conceptual, el prompt se divide inicialmente por su texto; el analista combina esos requisitos con el contexto recolectado para seleccionar los módulos correctos y aplicar sus restricciones tecnológicas. La memoria de negocio del módulo se incorpora más tarde dentro de la VM elegida.

La entrada principal es:

```bash
./tools/orquestacion/orquestar.sh "En comments agrega un endpoint para consultar comentarios y publica su contrato"
```

Para analizar sin ejecutar agentes:

```bash
./tools/orquestacion/orquestar.sh --clasificar "objetivo"
./tools/orquestacion/orquestar.sh --descomponer "objetivo"
```

Cuando un prompt contiene trabajo para más de un destino, los despachos se lanzan en paralelo en segundo plano y se esperan en conjunto. Un fallo no cancela silenciosamente el resto; el reporte conserva el resultado de cada VM.

Una oración que menciona inequívocamente varios módulos se expande a todos ellos. Las expresiones `solo lectura`, `sin modificar`, `no edites` y equivalentes activan una política fail-closed que elimina la escritura del workspace y la publicación en el Memory Gateway para todos los despachos de la solicitud.

---

## Estructura Modular de `tools/`

Las herramientas del orquestador están organizadas en 7 subcarpetas temáticas especializadas:

```text
tools/
├── orquestacion/              # Entrada principal, clasificación, análisis de requisitos y memoria
│   ├── orquestar.sh
│   ├── descomponer_requisitos.sh
│   ├── analizar_requisitos.sh
│   ├── clasificar_tarea.sh
│   ├── recolectar_contexto_memoria.sh
│   └── preparar_proyecto.sh
├── despacho/                  # Validación, candados de ejecución física y generación de reportes
│   ├── validar_y_despachar.sh
│   ├── despachar_vm.sh
│   ├── generar_evidencia_agente.sh
│   ├── generar_reporte.sh
│   └── pi_harness.sh
├── vms/                       # Provisionamiento, perfiles, llaves SSH y auditoría de VMs
│   ├── provisionar_vm_pi.sh
│   ├── configurar_perfil_backend_local.sh
│   ├── agregar_repositorio_vm.sh
│   ├── detectar_tecnologias_repositorio.sh
│   ├── limpiar_vm_pi.sh
│   ├── configurar_ssh_vm.sh
│   ├── probar_vms.sh
│   └── inicializar_memorias_negocio_vm.sh
├── sincronizacion/            # Sincronización Git de agentes y monitores de versión
│   ├── sincronizar_agente.sh
│   ├── sincronizar_agente_local.sh
│   ├── instalar_actualizacion_git.sh
│   ├── instalar_monitor_local.sh
│   └── monitor_agentes_locales.sh
├── gateway/                   # Servidor mTLS y exploradores CLI/visual de memoria
│   ├── provisionar_memory_gateway.sh
│   ├── configurar_memory_gateway.sh
│   ├── instalar_identidad_gateway.sh
│   ├── memoria_gateway.sh
│   ├── consultar_memoria.sh
│   ├── visualizar_grafos.py
│   └── visualizador_grafos.html
├── agentes/                   # Generación automatizada de nuevos agentes/skills
│   └── crear_agente.sh
└── remotos/                   # Bootstraps remotos ejecutados en VMs
    ├── actualizar_agente_git.sh
    ├── ciclo_actualizacion_git.sh
    ├── instalar_paquetes_backend.sh
    ├── provisionar_vm_pi.sh
    └── prueba-agentes-bwrap.apparmor
```

---

## Componentes y Ubicación

| Componente | Dónde vive | Responsabilidad |
|---|---|---|
| Orquestador `tools/*/*.sh` | Mac | Contexto, análisis, enrutamiento, SSH y consolidación |
| Generador de Agentes | Mac | `tools/agentes/crear_agente.sh` (crea automáticamente la suite en `skills/`) |
| Explorador de Memoria | Mac | `tools/gateway/consultar_memoria.sh` (CLI interactivo de contratos y memoria) |
| Visualizador de grafos | Mac | Python sirve el HTML local y consulta Cognee únicamente a través del Gateway |
| Agentes `skills/*` | Git y copia versionada en cada VM | Instrucciones especializadas por rol (`dev-back`, `dev-front`, `dev-analytics`, `dev-security`, `qa`) |
| Pi y `pi-harness` | Cada VM | Ejecución del agente y aislamiento del workspace |
| Memoria de negocio | Cada VM | Reglas privadas del repositorio seleccionado |
| Memory Gateway | Servidor central | mTLS, RBAC, contratos, auditoría y outbox con fallback SQLite |
| SQLite + OpenAPI | Servidor del Gateway | Fuente autoritativa de contratos compartidos |
| Cognee OSS | Servidor de memoria | Grafo de conocimiento y búsqueda semántica |
| Ollama | Servidor de memoria en esta prueba | LLM local utilizado por Cognee; no ejecuta los agentes |

---

## Guía de Instalación del Entorno Local

Esta sección permite configurar la máquina de un nuevo desarrollador desde cero para dejar operativo todo el entorno local (Ollama, Cognee, Memory Gateway y el Visualizador de Grafos).

### Paso 1: Requisitos Previos

Asegúrate de contar con las siguientes herramientas en tu equipo:
- **Node.js**: `v24.0.0` o superior (`node -v`).
- **Python**: `3.10` o superior (`python3 --version`).
- **Ollama**: Servicio activo con el modelo estructurado instalado:
  ```bash
  ollama pull hermes3:latest
  ```

### Paso 2: Inicializar la carpeta `.private/` (Ejecutar una sola vez)

La carpeta `.private/` está ignorada en `.gitignore` para proteger credenciales y datos locales. En un equipo nuevo, ejecuta este bloque desde la raíz del proyecto (`prueba_agentes`):

```bash
# 1. Crear el entorno virtual e instalar dependencias de Cognee
python3 -m venv .private/cognee-venv
.private/cognee-venv/bin/pip install --upgrade pip
.private/cognee-venv/bin/pip install cognee uvicorn fastembed

# 2. Generar la PKI local mTLS para el Memory Gateway
./memory-gateway/bin/generar_pki.sh .private/memory-gateway-pki 127.0.0.1 backend frontend orchestrator-analyst memory-admin
cp .private/memory-gateway-pki/server.key .private/memory-gateway-pki/server-local.key
cp .private/memory-gateway-pki/server.crt .private/memory-gateway-pki/server-local.crt

# 3. Crear directorios de datos, clientes de gateway e inventario inicial
mkdir -p .private/memory-gateway-data .private/memory-gateway-data/openapi
cp memory-gateway/config/clients.example.json .private/memory-gateway-clients.json
cp memoria/tecnologias.example.json .private/tecnologias.json
```

---

## Levantar los Servicios Locales en macOS

En este laboratorio, **Ollama, Cognee y el Memory Gateway se ejecutan en la Mac**. Los tres procesos se inician en terminales separadas y permanecen en primer plano (`Ctrl+C` para detenerlos).

Todos los comandos siguientes deben ejecutarse desde la raíz del repositorio.

### 1. Comprobar Ollama

Cognee utiliza un modelo Ollama con soporte de generación estructurada JSON (`hermes3:latest` o `qwen3:8b`). Ollama debe estar activo antes de iniciar Cognee:

```bash
curl --fail --silent http://127.0.0.1:11434/api/tags | jq '.models[].name'
```

Si no responde, abre la aplicación Ollama o inicia su servicio local. La lista debe incluir el modelo configurado (`hermes3:latest` o `qwen3:8b`).

### 2. Levantar Cognee — terminal 1

Este comando utiliza explícitamente `.private/cognee-system` y `.private/cognee-data`, donde vive la memoria existente. No se deben omitir estas rutas porque Cognee utilizaría sus directorios predeterminados y parecería que el grafo está vacío.

> *Nota*: Si no dispones de la biblioteca nativa `ladybug-v0.19.0`, omite las líneas de `GRAPH_DATABASE_PROVIDER`, `LBUG_C_API_LIB_PATH` y `DYLD_LIBRARY_PATH` para que Cognee utilice su proveedor por defecto (Kuzu/NetworkX).

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
  LLM_API_KEY=ollama \
  EMBEDDING_PROVIDER=fastembed \
  EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2 \
  EMBEDDING_DIMENSIONS=384 \
  "$PROJECT_ROOT/.private/cognee-venv/bin/uvicorn" \
  cognee.api.client:app --host 127.0.0.1 --port 8000
```

Cognee estará listo cuando muestre `Application startup complete`. Desde otra terminal se puede comprobar sin modificar la memoria:

```bash
curl --fail --silent http://127.0.0.1:8000/api/v1/datasets | jq 'map({id, name})'
```

### 3. Levantar el Memory Gateway — terminal 2

El Gateway es la única puerta de entrada a Cognee para el orquestador y el visor. Conserva SQLite/OpenAPI como fuente autoritativa y protege el acceso mediante mTLS y permisos.

```bash
PROJECT_ROOT="$PWD"

env \
  MEMORY_GATEWAY_HOST=127.0.0.1 \
  MEMORY_GATEWAY_PORT=9443 \
  MEMORY_GATEWAY_DB="$PROJECT_ROOT/.private/memory-gateway-data/gateway.sqlite" \
  MEMORY_GATEWAY_CLIENTS="$PROJECT_ROOT/.private/memory-gateway-clients.json" \
  MEMORY_GATEWAY_OPENAPI_DIR="$PROJECT_ROOT/.private/memory-gateway-data/openapi" \
  MEMORY_GATEWAY_TLS_KEY="$PROJECT_ROOT/.private/memory-gateway-pki/server-local.key" \
  MEMORY_GATEWAY_TLS_CERT="$PROJECT_ROOT/.private/memory-gateway-pki/server-local.crt" \
  MEMORY_GATEWAY_TLS_CA="$PROJECT_ROOT/.private/memory-gateway-pki/ca.crt" \
  COGNEE_BASE_URL=http://127.0.0.1:8000 \
  node memory-gateway/bin/memory-gateway.mjs
```

El Gateway estará listo cuando muestre `Memory Gateway escuchando en https://127.0.0.1:9443`. Para comprobarlo con la identidad administrativa:

```bash
PROJECT_ROOT="$PWD"
export MEMORY_GATEWAY_URL='https://127.0.0.1:9443'
export MEMORY_GATEWAY_CLIENT_CERT="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.crt"
export MEMORY_GATEWAY_CLIENT_KEY="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.key"
export MEMORY_GATEWAY_CA="$PROJECT_ROOT/.private/memory-gateway-pki/ca.crt"

./tools/gateway/memoria_gateway.sh verificar
```

La respuesta correcta contiene `"status":"ok"` y `"semantic_backend":"cognee-oss"`. Al iniciar, el Gateway también reintenta gradualmente los elementos pendientes de su outbox; por eso Cognee puede comenzar a procesar memoria aunque no se envíe un prompt nuevo.

### 4. Levantar el visualizador — terminal 3

Las variables se deben exportar nuevamente porque cada terminal tiene su propio entorno:

```bash
PROJECT_ROOT="$PWD"
export MEMORY_GATEWAY_URL='https://127.0.0.1:9443'
export MEMORY_GATEWAY_CLIENT_CERT="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.crt"
export MEMORY_GATEWAY_CLIENT_KEY="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.key"
export MEMORY_GATEWAY_CA="$PROJECT_ROOT/.private/memory-gateway-pki/ca.crt"

.private/cognee-venv/bin/python tools/gateway/visualizar_grafos.py --abrir
```

El visor estará disponible en `http://127.0.0.1:8765`. Se usa el Python del entorno Cognee porque el Python del sistema incluido en macOS puede utilizar LibreSSL sin soporte TLS 1.3.

### Detener y diagnosticar

Para detener cada componente, presiona `Ctrl+C` en su terminal, comenzando por el visor, luego el Gateway y finalmente Cognee. Para saber si ya existe una instancia y evitar `Address already in use`:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN   # Cognee
lsof -nP -iTCP:9443 -sTCP:LISTEN   # Memory Gateway
lsof -nP -iTCP:8765 -sTCP:LISTEN   # Visualizador
```

Si `8765` está ocupado y deseas conservar la instancia existente, abre `http://127.0.0.1:8765`. Para iniciar otra instancia deliberadamente, usa `--port 8766`.

### Reconstrucción segura de grafos (`reconstruir-grafos.mjs`)

Si necesitas borrar y regenerar todos los datasets de memoria semántica en Cognee a partir de las fuentes autoritativas (SQLite/OpenAPI para contratos y `.private/tecnologias.json` para tecnologías):

> **IMPORTANTE**: El Memory Gateway debe estar detenido durante este proceso para evitar escrituras concurrentes.

```bash
# 1. Crear respaldo y reconstruir datasets en Cognee
node memory-gateway/bin/reconstruir-grafos.mjs --confirmar-limpieza
```

El proceso realiza lo siguiente de forma segura:
- Genera automáticamente un respaldo completo con timestamp en `.private/graph-backups/YYYY-MM-DDTHH-MM-SS-sssZ/`.
- Elimina únicamente los datasets que inician con el prefijo `prueba_agentes_`.
- Indexa los modelos canónicos:
  - **Contratos compartidos** (`shared_contracts`): `Repositorio → Módulo → Endpoint`.
  - **Tecnologías privadas** (`company`): `Repositorio → Tecnología`.

---

## Creación Automatizada de Nuevos Agentes (`crear_agente.sh`)

Para crear un nuevo agente o skill con su suite completa de subagentes (`analista`, `generador-codigo`, `qa`, `documentador`), ejecuta:

```bash
# Modo interactivo (te preguntará nombre, descripción, misión y herramientas):
./tools/agentes/crear_agente.sh

# Modo directo de un solo comando:
./tools/agentes/crear_agente.sh dev-sec "Especialista en Seguridad" "Auditar código contra OWASP" "pi-harness,snyk"
```

El script genera automáticamente la estructura en `skills/<nombre>/` y realiza el `git add` correspondiente.

---

## Exploración CLI de Memoria y Contratos (`consultar_memoria.sh`)

Puedes explorar los contratos JSON registrados y las reglas corporativas directamente desde la terminal:

```bash
# Ver resumen general de la memoria
./tools/gateway/consultar_memoria.sh

# Listar todos los contratos de endpoints en tabla formateada
./tools/gateway/consultar_memoria.sh --contratos

# Buscar contratos o memorias por palabra clave
./tools/gateway/consultar_memoria.sh --buscar stats

# Inspeccionar el esquema JSON completo de un endpoint
./tools/gateway/consultar_memoria.sh --ver GET /api/posts/{id}/stats

# Listar las reglas de memoria corporativa (capa company)
./tools/gateway/consultar_memoria.sh --empresa
```

### Visualizador web del grafo de Cognee

El visor propio muestra los datasets, nodos y relaciones que Cognee va generando. Se actualiza automáticamente cada 15 segundos, permite buscar por significado, seleccionar una memoria, mover nodos, hacer zoom y revisar los datos de una entidad.

El navegador **no recibe certificados ni credenciales de Cognee**. Se conecta al servidor Python local; Python usa la identidad administrativa mTLS para consultar dos endpoints protegidos del Memory Gateway, y el Gateway sólo entrega datasets cuyo nombre comienza con `prueba_agentes_`.

La identidad usada debe incluir el permiso `graphs:read` en `clients.json`. Tanto `memory-gateway/config/clients.example.json` como la configuración privada actual contienen ese permiso. Para iniciar únicamente el visor cuando Cognee y el Gateway ya están activos:

```bash
PROJECT_ROOT="$PWD"
export MEMORY_GATEWAY_URL='https://127.0.0.1:9443'
export MEMORY_GATEWAY_CLIENT_CERT="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.crt"
export MEMORY_GATEWAY_CLIENT_KEY="$PROJECT_ROOT/.private/memory-gateway-pki/clients/memory-admin.key"
export MEMORY_GATEWAY_CA="$PROJECT_ROOT/.private/memory-gateway-pki/ca.crt"

./tools/gateway/memoria_gateway.sh verificar
.private/cognee-venv/bin/python tools/gateway/visualizar_grafos.py --abrir
```

Ejecuta el bloque desde la raíz de este repositorio. La guía **Levantar la memoria local en macOS** documenta el arranque completo. Se utiliza el Python del entorno Cognee porque incluye OpenSSL con soporte TLS 1.3; el Python del sistema de macOS puede estar enlazado con una versión antigua de LibreSSL. La comprobación `verificar` debe responder antes de abrir el visor.

El visualizador permanece en primer plano. Para detenerlo, vuelve a su terminal y presiona `Ctrl+C`. Si el puerto quedó ocupado por otra instancia, comprueba qué proceso lo usa con `lsof -nP -iTCP:8765 -sTCP:LISTEN`; también puedes iniciar una instancia independiente con `--port 8766`.

Sin `--abrir`, visita `http://127.0.0.1:8765`. El servidor se enlaza sólo a localhost de forma predeterminada y no requiere paquetes Python externos. Cuando se agrega y procesa nueva memoria con `add → cognify`, la siguiente actualización refleja el crecimiento del grafo. Si Cognee está caído, la búsqueda normal conserva el fallback SQLite, pero el grafo no puede representarse porque SQLite no contiene las relaciones semánticas generadas por Cognee.

---

## Las Tres Capas de Memoria

### 1. Tecnología privada de la empresa

La consume el recolector/analista antes de enrutar los requisitos. Puede mantenerse en `.private/tecnologias.json` usando [`memoria/tecnologias.example.json`](memoria/tecnologias.example.json) como plantilla, o publicarse en la capa `company` del Gateway.

La identidad `orchestrator-analyst` sólo puede leer esta capa. Los agentes reciben únicamente el fragmento tecnológico relevante para su requisito.

#### Detección automática al agregar un repositorio

El asistente inicial `provisionar_vm_pi.sh` y el alta adicional `agregar_repositorio_vm.sh` inspeccionan el repositorio local antes de registrarlo. Leen únicamente sus manifiestos; no instalan dependencias ni ejecutan código del proyecto. Reconocen actualmente:

- PHP, Laravel, Illuminate y Composer mediante `composer.json`.
- Node.js, Vue, React, Next.js, Nuxt, Vite, TypeScript y el gestor de paquetes mediante `package.json` y sus archivos de lock.
- Python, Go, Rust, Ruby, Java/Maven, Gradle, .NET y Docker mediante sus manifiestos convencionales.

El resultado se guarda automáticamente en `.private/tecnologias.json` bajo una clave idéntica al `repo-id` registrado en `config/vms.json`:

```json
{
  "version": 1,
  "repositories": {
    "modulo-inventario": {
      "technologies": ["Composer", "Illuminate ^13.0", "PHP ^8.4"],
      "architecture": "módulo backend Illuminate/Composer",
      "constraints": [],
      "detection": {
        "mode": "automatic",
        "sources": ["composer.json"]
      }
    }
  }
}
```

Si ya existe una entrada tecnológica para ese `repo-id`, por defecto se conserva. Para forzar la re-detección de manifiestos y actualizar el registro (por ejemplo, si agregaste nuevos paquetes o dependencias), usa el flag `--refrescar-tecnologias`:

```bash
./tools/vms/agregar_repositorio_vm.sh perfil repo-id modulo module /ruta/local /home/user/remote 'alias1,alias2' --solo-configurar --refrescar-tecnologias
```

#### Sincronización Automática a la Capa `company` del Gateway
Al registrar o refrescar la tecnología de un repositorio, el sistema sincroniza automáticamente un resumen estructurado con la capa `company` del Memory Gateway (`memoria_gateway.sh guardar-tecnologias`). Esto permite que el analista orquestador recupere la información tecnológica centralizada mediante mTLS.

La detección también puede ejecutarse en consola sin registrar el repositorio:

```bash
./tools/vms/detectar_tecnologias_repositorio.sh /ruta/al/repositorio module
```

Los valores detectados son las restricciones declaradas en los manifiestos, no una garantía de las versiones instaladas en la VM.

#### Soporte de Despacho Remoto para Roles `qa` y `dev-security`
El orquestador (`orquestar.sh` y `analizar_requisitos.sh`) admite el despacho remoto automático por SSH para los cuatro stacks de agentes: `backend`, `frontend`, `qa` y `security`. Cuando configuras una VM con `"stack": "qa"` o `"stack": "security"`, las tareas de auditoría de código o generación de suites de pruebas E2E son asignadas y despachadas automáticamente a dicha máquina.

### 2. Contratos compartidos

Contiene endpoints necesarios para que el core, los módulos y el frontend se integren. Backend puede publicar mediante la herramienta de memoria expuesta por `pi-harness`; frontend normalmente sólo consulta.

SQLite y OpenAPI son autoritativos. Cognee ofrece recuperación semántica. El Memory Gateway incluye **fallback automático a SQLite**: si Cognee OSS no responde o está en mantenimiento, el Gateway consulta directamente a SQLite sin interrumpir el flujo.

### 3. Memoria de negocio local

Cada repositorio declara `business_memory` en `config/vms.json`. El archivo vive únicamente en la VM, con permisos `0600`; no vuelve a la Mac, no aparece en los logs y no se guarda en el reporte. `pi-harness` lo incorpora sólo después de elegir el destino.

---

## Seguridad

- Cada VM posee certificado y llave mTLS propios. El `CN` identifica el perfil.
- El Gateway aplica permisos, `core_id` y `tenant_id` desde `clients.json`.
- Las VMs nunca reciben credenciales directas de Cognee.
- La visualización requiere una identidad administrativa con `graphs:read`; el Gateway filtra los datasets ajenos al sistema.
- `pi-harness/policies/backend.json` y `frontend.json` definen rutas y comandos permitidos.
- En Linux se usa Bubblewrap; macOS usa Seatbelt y Windows requiere `pi-appcontainer`.
- El flujo es *fail-closed*: si falla la política, sincronización o memoria requerida, Pi no se ejecuta reutilizando estado antiguo.

---

## Provisionamiento de una VM Pi

Para aprovisionar una máquina virtual nueva de extremo a extremo:

```bash
# Paso 1: Copiar tu llave SSH a la VM
./tools/vms/configurar_ssh_vm.sh usuario@ip_de_la_vm

# Paso 2: Provisionar la VM con el asistente interactivo (incluye menú de selección de agentes en skills/)
./tools/vms/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo

# Auditar o verificar un perfil en cualquier momento sin reinstalar
./tools/vms/provisionar_vm_pi.sh <perfil> --solo-verificar
```

Cuando el perfil todavía no existe, el flujo interactivo:

1. Solicita la IP, el usuario y el origen del proyecto.
2. Busca repositorios en el directorio padre de este proyecto —normalmente `/Users/carlos/Documents/GitHub`— y muestra una lista numerada. Se puede definir otra raíz con `PRUEBA_AGENTES_REPOSITORIES_ROOT` o elegir una ruta manual.
3. Detecta las tecnologías del repositorio seleccionado, propone `backend` o `frontend` y usa el nombre de la carpeta como `repo-id` predeterminado.
4. Registra el perfil en `config/vms.json` y la tecnología en `.private/tecnologias.json`.
5. Continúa con el agente de `skills/`, workspace, actualización, rama, intervalo y versiones.

La selección y detección local también se ejecutan con `--solo-configurar`, por lo que es posible preparar y revisar el perfil sin conectarse todavía a la VM. Para proyectos configurados exclusivamente mediante una URL Git no existe una copia local que inspeccionar durante esta fase; su tecnología debe registrarse cuando haya una copia local disponible.

Para retirar los artefactos administrados por este orquestador antes de reprovisionar:

```bash
./tools/vms/limpiar_vm_pi.sh <perfil> --confirmar-limpieza
```

---

## Sincronización Automática de Agentes desde Git

Los agentes pueden actualizarse de dos maneras:

- `agent_update_mode: git`: la VM consulta periódicamente `git_branch` y activa `remote_agent/actual` mediante enlace simbólico atómico.
- `agent_update_mode: local`: el monitor de macOS copia el agente únicamente cuando cambia su hash de contenido.

Flujo de actualización Git:

```text
editar agente en skills/ → git add → git commit → git push a git_branch
                                         ↓
VM consulta origin → descarga git_agent_path → activa nueva versión en ~/agentes/<agente>/actual
```

Para solicitar la comprobación inmediatamente sin esperar al cron:

```bash
./tools/sincronizacion/sincronizar_agente.sh <perfil>
```

---

## Pi Harness y Aislamiento

El harness instalado en cada VM:

1. Detecta el sistema operativo (Linux / macOS / Windows).
2. Selecciona Bubblewrap en Linux, Seatbelt en macOS o `pi-appcontainer` en Windows.
3. Carga `pi-harness/policies/<rol>.json`.
4. Carga únicamente el agente y la extensión de seguridad seleccionados.
5. Incorpora la memoria de negocio local del repositorio.
6. Guarda manifiesto, eventos, errores y auditoría de herramientas.
7. En modo solo lectura genera una política efectiva sin escritura y sin herramientas de publicación de memoria.
8. Conserva el JSONL bruto en la VM y devuelve a la Mac únicamente la respuesta final saneada.

Diagnóstico local del harness:

```bash
./tools/despacho/pi_harness.sh doctor \
  --role backend \
  --workspace /ruta/proyecto \
  --agent-dir ./skills/dev-back

./tools/despacho/pi_harness.sh start \
  --role backend \
  --workspace /ruta/proyecto \
  --agent-dir ./skills/dev-back \
  --task "Agrega una prueba" \
  --dry-run
```

---

## Artefactos de una Ejecución

Cada solicitud crea `logs/<slug>/` con:

- `SOLICITUD.md`: prompt original.
- `CONTEXTO_RECOLECTADO.json`: contexto mínimo utilizado por el analista.
- `REQUISITOS.json` y `REQUISITOS.md`: requisitos y destinos seleccionados.
- `*_output.log`: salida de cada ejecución remota.
- `EVIDENCIA_AGENTES.md`: VM, agente, versión, hash, commit, Pi, workspace y `run_id`.
- `REPORTE_PI.md`: consolidación final.

---

## Diagnóstico y Suites de Pruebas

```bash
# Diagnóstico SSH a las VMs configuradas
./tools/vms/probar_vms.sh

# Verificación de perfiles
./tools/vms/provisionar_vm_pi.sh <perfil> --solo-verificar

# Suites de Pruebas Automatizadas
./tests/probar_automatizacion.sh
node tests/probar_memory_gateway.mjs
bash tests/probar_enrutamiento_modular.sh
bash tests/probar_clasificacion.sh
node tests/probar_extension_pi.mjs
bash tests/probar_despacho_paralelo.sh
bash tests/probar_pi_harness.sh
bash tests/probar_provisionamiento_pi.sh
bash tests/probar_sincronizacion.sh
bash tests/probar_ciclo_actualizacion.sh
bash tests/probar_monitor_local.sh
bash tests/probar_creacion_agente.sh
bash tests/probar_consultar_memoria.sh
python3 tests/probar_visualizador_grafos.py
```

---

## Estado del Laboratorio

- `backend-core`: `192.168.50.193`, repositorio `api-monolitic`.
- `backend-comments`: `192.168.50.40`, repositorio `api-monolitic-comments`.
- `backend-posts`: `192.168.50.231`, repositorio `api-monolitic-posts`.
- Las tres VMs responden por SSH, tienen Pi, `pi-harness`, identidad mTLS y memoria habilitada.
- Cognee y el Gateway se ejecutan en la Mac. Para administración local, Cognee escucha en `127.0.0.1:8000` y el Gateway mTLS en `https://127.0.0.1:9443`.
- Cognee 1.5.3 reutiliza la memoria persistente de `.private/cognee-system`; Ollama aporta `qwen3:8b` y FastEmbed genera los embeddings locales.
- El Gateway local utiliza un certificado `server-local` válido para localhost. La identidad `memory-admin` dispone de `graphs:read`, sin entregar credenciales de Cognee al navegador.
- El visor Python/HTML fue probado con los datasets reales `contracts` y `company`; durante la comprobación mostró 56 nodos y 110 relaciones en el grafo de contratos.
- **100% de las suites de pruebas pasando de forma limpia.**
- Ejecución distribuida paralela verificada en vivo enviando tareas simultáneas a los módulos `posts` y `comments`.
