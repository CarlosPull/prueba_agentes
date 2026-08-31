# Orquestador distribuido de agentes con Pi y memoria compartida

Este repositorio contiene un orquestador local escrito en shell. Recibe un prompt libre, recopila contexto de memoria, lo divide en requisitos atómicos, selecciona la VM y el repositorio correctos y ejecuta cada subtarea mediante **Pi** y `pi-harness` dentro de la VM. La Mac no ejecuta Pi ni modifica directamente los repositorios remotos.

> El flujo anterior basado en Python, OpenCode o `agent-runner` fue retirado. El motor de ejecución actual es exclusivamente Pi.

## Flujo completo

```text
Prompt del usuario en la Mac
        │
        ▼
Recolector de contexto
  ├─ inventario de perfiles y repositorios de config/vms.json
  ├─ tecnología privada relevante
  └─ contratos compartidos recuperados por el Memory Gateway
        │
        ▼
Analista de requisitos
  ├─ divide el prompt en requisitos backend/frontend/general
  ├─ selecciona perfil, VM, repositorio y módulo
  └─ rechaza destinos ambiguos
        │
        ▼
Despachos SSH en paralelo
        │
        ├─ VM del core
        ├─ VM de comments
        ├─ VM de posts
        └─ VM frontend cuando esté habilitada
                │
                ▼
        Pi + pi-harness + agente de la VM
          ├─ aplica la política del rol
          ├─ incorpora memoria de negocio local
          ├─ modifica únicamente el workspace permitido
          └─ consulta/publica contratos mediante mTLS
                │
                ▼
Reporte, logs y evidencia en logs/<slug>/
```

La entrada normal es:

```bash
./tools/orquestar.sh "En comments agrega un endpoint para consultar comentarios y publica su contrato"
```

Para analizar sin ejecutar agentes:

```bash
./tools/orquestar.sh --clasificar "objetivo"
./tools/orquestar.sh --descomponer "objetivo"
```

Cuando un prompt contiene trabajo para más de un destino, los despachos se lanzan en segundo plano y se esperan en conjunto. Un fallo no cancela silenciosamente el resto; el reporte conserva el resultado de cada VM.

## Componentes y ubicación

| Componente | Dónde vive | Responsabilidad |
|---|---|---|
| Orquestador `tools/*.sh` | Mac | Contexto, análisis, enrutamiento, SSH y consolidación |
| Agentes `skills/*` | Git y copia versionada en cada VM | Instrucciones especializadas por rol |
| Pi y `pi-harness` | Cada VM | Ejecución del agente y aislamiento del workspace |
| Memoria de negocio | Cada VM | Reglas privadas del repositorio seleccionado |
| Memory Gateway | Servidor central | mTLS, RBAC, contratos, auditoría y outbox |
| SQLite + OpenAPI | Servidor del Gateway | Fuente autoritativa de contratos compartidos |
| Cognee OSS | Servidor de memoria | Grafo de conocimiento y búsqueda semántica |
| Ollama | Servidor de memoria en esta prueba | LLM local utilizado por Cognee; no ejecuta los agentes |
| FastEmbed | Servidor de memoria | Embeddings locales usados por Cognee |

Ollama es reemplazable por otro proveedor compatible. Cognee necesita un LLM para extraer relaciones y generar el grafo, pero las VMs de desarrollo no necesitan instalar Ollama.

## Las tres capas de memoria

### 1. Tecnología privada de la empresa

La consume el recolector/analista antes de clasificar. Puede mantenerse en `.private/tecnologias.json` usando [`memoria/tecnologias.example.json`](memoria/tecnologias.example.json) como plantilla, o publicarse en la capa `company` del Gateway. El archivo real está ignorado por Git.

La identidad `orchestrator-analyst` sólo puede leer esta capa. Los agentes reciben únicamente el fragmento tecnológico relevante para su requisito.

### 2. Contratos compartidos

Contiene endpoints necesarios para que el core, los módulos y el frontend se integren. Backend puede publicar mediante la herramienta de memoria expuesta por `pi-harness`; frontend normalmente sólo consulta.

SQLite y OpenAPI son autoritativos. Cognee ofrece recuperación semántica. Si Cognee está temporalmente fuera de servicio, el contrato no se pierde: queda en la tabla `outbox` hasta poder indexarse.

### 3. Memoria de negocio local

Cada repositorio declara `business_memory` en `vms.json`. El archivo vive únicamente en la VM, con permisos `0600`; no vuelve a la Mac, no aparece en los logs y no se guarda en el reporte. `pi-harness` lo incorpora sólo después de elegir el destino.

## Seguridad

- Cada VM posee certificado y llave mTLS propios. El `CN` identifica el perfil.
- El Gateway aplica permisos, `core_id` y `tenant_id` desde `clients.json`.
- Las VMs nunca reciben credenciales directas de Cognee.
- La identidad administrativa que escribe memorias privadas es distinta de las identidades de agentes.
- `pi-harness/policies/backend.json` y `frontend.json` definen rutas y comandos permitidos.
- En Linux se usa Bubblewrap; macOS usa Seatbelt y Windows requiere `pi-appcontainer`.
- El flujo es *fail-closed*: si falla la política, sincronización o memoria requerida, Pi no se ejecuta reutilizando estado antiguo.
- Toda autorización o denegación del Gateway se registra en SQLite.

## Configuración de VMs y repositorios

`config/vms.json` admite varios perfiles del mismo stack. Cada perfil activo debe declarar Pi y uno o más repositorios:

```json
{
  "backend-comments": {
    "ip": "192.168.50.40",
    "user": "serveradmin",
    "stack": "backend",
    "engine": "pi",
    "dispatch_enabled": true,
    "pi_harness": "/home/serveradmin/.local/bin/pi-harness",
    "repositories": [{
      "id": "api-monolitic-comments",
      "module": "comments",
      "kind": "module",
      "path": "/home/serveradmin/api-monolitic-comments",
      "business_memory": "/home/serveradmin/.local/share/prueba-agentes/business/api-monolitic-comments.md",
      "aliases": ["comentario", "comentarios", "comments"]
    }]
  }
}
```

`kind` acepta `core`, `module` o `frontend`. Los alias ayudan al analista determinista. Si dos destinos empatan, el proceso devuelve `ROUTING_AMBIGUO` en lugar de escoger arbitrariamente.

Para añadir otro repositorio a una VM provisionada:

```bash
./tools/agregar_repositorio_vm.sh \
  backend-comments modulo-extra extra module \
  /ruta/local/modulo-extra \
  /home/serveradmin/modulo-extra \
  'extra,alias-secundario'
```

Para crear sin preguntas un perfil backend cuyo repositorio ya existe en la Mac:

```bash
./tools/configurar_perfil_backend_local.sh \
  <perfil> <ip> <usuario> <ruta-local> <core|module> \
  <repo-id> <modulo> 'alias-1,alias-2'
```

Los repositorios `core` deben tener `composer.json` y `artisan`. Los repositorios `module` sólo requieren `composer.json` y no ejecutan la inicialización de una aplicación Laravel completa.

## Provisionar una VM Pi

Para un perfil existente o uno nuevo:

```bash
./tools/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo
./tools/provisionar_vm_pi.sh <perfil> --solo-verificar
```

El provisionador configura acceso SSH por llave, paquetes, NVM/Node, Pi, `pi-harness`, PHP/Composer cuando corresponde, proyecto, agente, memoria local y actualización automática del agente. Si el perfil no existe, solicita sus datos y lo agrega atómicamente a `vms.json`.

El flujo interactivo solicita IP, usuario, stack, workspace, origen del proyecto, modo de actualización del agente, rama, intervalo y versiones. Los valores quedan en `vms.json`; no están hardcodeados en el script. `source_mode: local` copia el proyecto existente de la Mac durante el aprovisionamiento. `source_mode: git` lo clona desde su remoto.

Si el repositorio privado se obtiene mediante Git, puede entregarse temporalmente un token sólo durante el provisionamiento:

```bash
export GITHUB_TOKEN='token-con-acceso-de-lectura'
./tools/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo
unset GITHUB_TOKEN
```

El token se usa mediante un `GIT_ASKPASS` temporal y no se guarda en la VM ni en `vms.json`. Con `source_mode: local` no es necesario.

Para retirar únicamente los artefactos administrados por este orquestador antes de reprovisionar:

```bash
./tools/limpiar_vm_pi.sh <perfil> --confirmar-limpieza
```

La limpieza conserva Ubuntu, PHP, Node, Pi y la sesión autenticada de Pi.

Los agentes pueden actualizarse de dos maneras:

- `agent_update_mode: git`: la VM consulta periódicamente `git_branch` y activa `remote_agent/actual` mediante enlace simbólico atómico.
- `agent_update_mode: local`: el monitor de macOS copia el agente únicamente cuando cambia su hash de contenido.

En modo Git, `tools/instalar_actualizacion_git.sh` instala en la VM un cron por rol. Cron despierta cada minuto y el actualizador ejecuta comprobaciones internas según `agent_poll_seconds` (`10`, `15`, `20`, `30` o `60`). La VM descarga `git_branch`, extrae únicamente `git_agent_path`, versiona por el árbol Git y cambia `remote_agent/actual` mediante un enlace simbólico atómico. Un bloqueo exclusivo impide activar una versión mientras Pi está ejecutándose.

Por tanto, un cambio local llega a una VM Git sólo después de:

```text
editar → git add → git commit → git push a git_branch
                         ↓
VM consulta origin → descarga git_agent_path → activa nueva versión
```

Para solicitar la comprobación inmediatamente, sin esperar al siguiente ciclo:

```bash
./tools/sincronizar_agente.sh <perfil>
```

## Pi harness y aislamiento

El harness instalado en cada VM:

1. Detecta el sistema operativo.
2. Selecciona Bubblewrap en Linux, Seatbelt en macOS o `pi-appcontainer` en Windows.
3. Falla antes de ejecutar Pi si la barrera requerida no existe.
4. Carga `pi-harness/policies/<rol>.json`.
5. Crea un `HOME` temporal y deshabilita el descubrimiento de instrucciones, skills y extensiones ajenas.
6. Carga únicamente el agente y la extensión de seguridad seleccionados.
7. Incorpora la memoria de negocio local del repositorio.
8. Guarda manifiesto, eventos, errores y auditoría de herramientas.

No se usa Docker ni un contenedor de aplicación. Bubblewrap y Seatbelt aíslan directamente el proceso Pi. Windows permanece *fail-closed* hasta que exista el ejecutable nativo `pi-appcontainer`.

La extensión valida `read`, `grep`, `find`, `ls`, `write` y `edit`. Las reglas son rutas relativas exactas o directorios terminados en `/**`; `deny_read` y `deny_write` siempre tienen prioridad. Los enlaces simbólicos que salen del workspace son rechazados. Los comandos de shell sólo se habilitan cuando el harness confirma que la barrera física está activa.

Diagnóstico local del harness:

```bash
./tools/pi_harness.sh doctor \
  --role backend \
  --workspace /ruta/proyecto \
  --agent-dir ./skills/dev-back

./tools/pi_harness.sh start \
  --role backend \
  --workspace /ruta/proyecto \
  --agent-dir ./skills/dev-back \
  --task "Agrega una prueba" \
  --dry-run
```

En una VM, los registros en vivo están en:

```text
~/.local/state/pi-harness/runs/<run_id>/manifest.json
~/.local/state/pi-harness/runs/<run_id>/tool-calls.jsonl
~/.local/state/pi-harness/runs/<run_id>/events.jsonl
~/.local/state/pi-harness/runs/<run_id>/stderr.log
```

Ejemplos para observar una ejecución:

```bash
find ~/.local/state/pi-harness/runs -mindepth 1 -maxdepth 1 -type d | sort | tail -1
tail -f ~/.local/state/pi-harness/runs/<run_id>/events.jsonl
tail -f ~/.local/state/pi-harness/runs/<run_id>/tool-calls.jsonl
```

## Memory Gateway, Cognee y Ollama

La topología implementada es:

```text
VMs Pi ── HTTPS/mTLS ── Memory Gateway ── HTTP privado ── Cognee OSS
                              │                         ├─ Ollama (LLM)
                              ├─ SQLite                 └─ FastEmbed
                              └─ OpenAPI 3.1
```

### PKI e identidades

```bash
./memory-gateway/bin/generar_pki.sh \
  ./.private/memory-gateway-pki \
  192.168.50.31 \
  backend-core backend-comments backend-posts orchestrator-analyst memory-admin

./tools/instalar_identidad_gateway.sh backend-core ./.private/memory-gateway-pki
./tools/instalar_identidad_gateway.sh backend-comments ./.private/memory-gateway-pki
./tools/instalar_identidad_gateway.sh backend-posts ./.private/memory-gateway-pki
```

La CA privada y las llaves deben permanecer fuera de Git.

El archivo `clients.json` registra cada identidad y limita sus permisos, `core_ids` y `tenant_ids`. Las identidades backend tienen lectura/escritura de contratos de su core; frontend sólo lectura; `orchestrator-analyst` sólo recolecta contratos y tecnología; `memory-admin` es la única identidad que escribe capas privadas.

### Configuración de Cognee local usada en la prueba

La prueba actual usa Cognee 1.5.3, Ollama y `qwen3:8b`, FastEmbed con MiniLM y almacenamiento local ignorado por Git. Cognee se inicia con el adaptador de salida estructurada para Ollama:

Instalación de referencia:

```bash
python3 -m venv .venv-cognee
.venv-cognee/bin/pip install 'cognee[fastembed]'
ollama pull llama3.1:8b
```

```bash
export LLM_PROVIDER='ollama'
export LLM_MODEL='qwen3:8b'
export LLM_ENDPOINT='http://127.0.0.1:11434/v1'
export LLM_API_KEY='ollama'
export STRUCTURED_OUTPUT_FRAMEWORK='litellm_instructor'
export EMBEDDING_PROVIDER='fastembed'
export EMBEDDING_MODEL='sentence-transformers/all-MiniLM-L6-v2'
export EMBEDDING_DIMENSIONS='384'

.venv-cognee/bin/uvicorn cognee.api.client:app \
  --host 127.0.0.1 --port 8000 --workers 1
```

`LLM_API_KEY=ollama` es sólo un valor no vacío exigido por el cliente; Ollama local no lo valida ni cobra consumo. Para producción conviene usar un modelo validado por Cognee, como Llama 3.1/3.2, y fijar las versiones de Cognee y del modelo.

En macOS ARM esta prueba necesitó librerías locales de LadybugDB y OpenSSL bajo `.private/`; no se modificó el OpenSSL del sistema.

### Ejecutar el Gateway

El ejemplo de entorno está en [`memory-gateway/config/gateway.env.example`](memory-gateway/config/gateway.env.example). Además de TLS, rutas y `COGNEE_BASE_URL`, admite tiempos mayores para modelos locales:

```bash
COGNEE_SEARCH_TYPE=CHUNKS
COGNEE_ADD_TIMEOUT_MS=60000
COGNEE_COGNIFY_TIMEOUT_MS=600000
COGNEE_SEARCH_TIMEOUT_MS=300000
```

`CHUNKS` hace búsqueda vectorial sin otra generación LLM y es la opción recomendada para el analista: reduce la latencia y devuelve el contenido fuente. Ollama continúa siendo utilizado al indexar y construir el grafo. `GRAPH_COMPLETION` puede habilitarse para respuestas conversacionales, pero es más lento.

```bash
node memory-gateway/bin/memory-gateway.mjs
```

Para instalarlo como servicio endurecido de `systemd`:

```bash
./tools/provisionar_memory_gateway.sh \
  administrador@192.168.50.10 \
  ./directorio-pki \
  ./clients.json
```

El servicio usa un usuario dedicado, filesystem protegido y escritura limitada al volumen de datos. Si Cognee tiene autenticación, sólo el Gateway recibe `COGNEE_API_KEY` o `COGNEE_BEARER_TOKEN`; estas credenciales nunca se entregan a las VMs.

### Habilitar memoria en perfiles

```bash
./tools/configurar_memory_gateway.sh \
  'https://192.168.50.31:9443' \
  api-monolitic empresa-prueba \
  backend-core backend-comments backend-posts
```

Las opciones `--leer-negocio` y `--leer-empresa` son explícitas. Sin ellas esas capas no se exponen al agente, aunque el analista central pueda tener una identidad separada de sólo lectura.

Para que el orquestador recolecte memoria privada se definen localmente:

```bash
export MEMORY_GATEWAY_COLLECTOR_CERT="$PWD/.private/memory-gateway-pki/clients/orchestrator-analyst.crt"
export MEMORY_GATEWAY_COLLECTOR_KEY="$PWD/.private/memory-gateway-pki/clients/orchestrator-analyst.key"
export MEMORY_GATEWAY_CA="$PWD/.private/memory-gateway-pki/ca.crt"
```

### Administración de memorias

```bash
export MEMORY_GATEWAY_URL='https://192.168.50.31:9443'
export MEMORY_GATEWAY_CLIENT_CERT="$PWD/.private/memory-gateway-pki/clients/memory-admin.crt"
export MEMORY_GATEWAY_CLIENT_KEY="$PWD/.private/memory-gateway-pki/clients/memory-admin.key"
export MEMORY_GATEWAY_CA="$PWD/.private/memory-gateway-pki/ca.crt"

./tools/memoria_gateway.sh verificar
./tools/memoria_gateway.sh guardar-negocio empresa-prueba 'Regla privada del negocio'
./tools/memoria_gateway.sh guardar-empresa 'PHP 8.4, Laravel 13 y convenciones internas'
```

Las VMs nunca se conectan directamente a Cognee. Las credenciales mTLS se entregan a la extensión del harness y se consumen antes de que el agente pueda lanzar herramientas. El Gateway registra publicaciones primero en SQLite/OpenAPI y luego las indexa en Cognee. Si la indexación falla, `outbox` conserva el trabajo para reintento.

## Artefactos de una ejecución

Cada solicitud crea `logs/<slug>/` con:

- `SOLICITUD.md`: prompt original.
- `CONTEXTO_RECOLECTADO.json`: contexto mínimo utilizado por el analista.
- `REQUISITOS.json` y `REQUISITOS.md`: requisitos y destinos seleccionados.
- `*_output.log`: salida de cada ejecución remota.
- `EVIDENCIA_AGENTES.md`: VM, agente, versión, hash, Pi, workspace y `run_id`.
- `REPORTE_PI.md`: consolidación final.

El contexto persistido no contiene la memoria local de negocio ni el registro tecnológico privado completo.

## Diagnóstico y pruebas

```bash
./tools/probar_vms.sh
./tools/provisionar_vm_pi.sh <perfil> --solo-verificar
node tests/probar_memory_gateway.mjs
bash tests/probar_provisionamiento_pi.sh
bash tests/probar_enrutamiento_modular.sh
```

La prueba de memoria levanta una CA y servicios temporales y verifica `add → cognify → search`, mTLS, RBAC, aislamiento por tenant, OpenAPI, SQLite, auditoría y consumo desde Pi.

Comprobar directamente el Gateway con una identidad válida:

```bash
export MEMORY_GATEWAY_URL='https://192.168.50.31:9443'
export MEMORY_GATEWAY_CLIENT_CERT='./.private/memory-gateway-pki/clients/memory-admin.crt'
export MEMORY_GATEWAY_CLIENT_KEY='./.private/memory-gateway-pki/clients/memory-admin.key'
export MEMORY_GATEWAY_CA='./.private/memory-gateway-pki/ca.crt'

./tools/memoria_gateway.sh verificar
```

Consultar el estado autoritativo local:

```bash
sqlite3 .private/memory-gateway-data/gateway.sqlite '.tables'
sqlite3 .private/memory-gateway-data/gateway.sqlite 'select * from contracts;'
sqlite3 .private/memory-gateway-data/gateway.sqlite 'select * from outbox;'
```

## Estado del laboratorio

- `backend-core`: `192.168.50.193`, repositorio `api-monolitic`.
- `backend-comments`: `192.168.50.40`, repositorio `api-monolitic-comments`.
- `backend-posts`: `192.168.50.231`, repositorio `api-monolitic-posts`.
- Las tres VMs responden por SSH, tienen Pi, `pi-harness`, identidad mTLS y memoria habilitada.
- El Gateway de prueba escucha en `https://192.168.50.31:9443`.
- SQLite/OpenAPI conservan los contratos y Cognee los indexa semánticamente con un modelo local servido por Ollama.
- La indexación real del contrato `POST /api/auth/login` y de la capa tecnológica terminó con `outbox` vacío.
- La búsqueda del analista usa `CHUNKS` para evitar una generación LLM adicional durante cada clasificación.
- La última prueba integral detectó dos defectos antes de modificar código: prioridad incorrecta de alias del enrutador y uso de `--keep-fd` no soportado por Bubblewrap 0.11.1. El enrutamiento ya fue corregido y cubierto por prueba; la compatibilidad de credenciales mTLS con Bubblewrap queda como siguiente corrección antes de repetir el despacho.

Las IP y rutas son datos del laboratorio actual, no valores que deban reutilizarse sin revisar `vms.json`.
