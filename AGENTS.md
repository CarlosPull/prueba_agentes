# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido (shell scripts puros, sin Python). Coordina agentes especializados definidos en Markdown dentro de `skills/`. Ejecuta `agent-runner` sobre VMs remotas vía SSH.

> **Nota sobre el README**: el `README.md` describe un sistema anterior basado en Python (`./bin/orquesta`, `runtime/orquestador.py`). La versión actual usa únicamente `tools/*.sh`. No sigas los comandos del README.

## Comandos esenciales (`tools/`)

Secuencia obligatoria para ejecutar una tarea:

```bash
./tools/orquestar.sh "objetivo"                       # entrada normal: clasifica y ejecuta todo el flujo
```

La secuencia interna, disponible también para diagnóstico manual, es:

```bash
./tools/probar_vms.sh                                # 1. diagnosticar SSH a VMs
./tools/preparar_proyecto.sh "objetivo"               # 2. crear carpeta proyecto + SOLICITUD.md
./tools/validar_y_despachar.sh <rol> <dir> "tarea"    # 3. despacho con bloqueo físico de re-despacho
./tools/generar_reporte.sh <dir> "tarea"              # 4. consolidar reporte en AGENT_RUNNER.md
```

Utilidades auxiliares:

```bash
./tools/orquestar.sh --clasificar "objetivo"          # mostrar el rol sin ejecutar agentes
./tools/clasificar_tarea.sh "objetivo"                # clasificador determinista directo
./tools/generar_evidencia_agente.sh <rol> <dir>       # evidencia del agente ejecutado en la VM
./tools/configurar_ssh_vm.sh user@ip                  # copiar llave SSH a VM nueva
./tools/provisionar_vm.sh <rol> --con-sudo-interactivo # preparar una VM nueva de extremo a extremo
./tools/provisionar_vm.sh <rol> --solo-verificar       # auditar una VM sin instalar dependencias
./tools/provisionar_vm_pi.sh <rol> --con-sudo-interactivo # preparar una VM nueva con Pi, sin agent-runner/OpenCode
./tools/provisionar_vm_pi.sh <rol> --solo-verificar    # auditar la instalación experimental de Pi
./tools/provisionar_vm_pi.sh <rol> --solo-configurar   # crear interactivamente el perfil en vms.json sin usar SSH
./tools/instalar_actualizacion_git.sh <rol>            # instalar el pull Git automático (una vez por VM)
./tools/sincronizar_agente.sh <rol>                   # solicitar inmediatamente un pull Git en la VM
./tools/sincronizar_agente_local.sh <perfil-vm>       # copiar y activar inmediatamente un agente local
./tools/instalar_monitor_local.sh                     # instalar monitor macOS cada 30 segundos
./tools/despachar_vm.sh <rol> <dir> "tarea"           # despacho directo (sin lock; usar validar_y_despachar en su lugar)
./tools/pi_harness.sh doctor ...                      # auditar localmente la futura ejecución con Pi
./tools/pi_harness.sh start ...                       # probar el harness de Pi sin pasar por el despachador
```

> **Importante**: `despachar_vm.sh` invoca primero `sincronizar_agente.sh`, que ordena a la VM consultar Git; no copia archivos desde la Mac. Cada rol declara en `vms.json` su `git_branch`, `git_agent_path` y `remote_agent`. La VM construye el prompt leyendo `remote_agent/actual/SKILL.md` y los recursos Markdown asociados.

## Estructura clave

```
skills/                        # Agentes y sus instrucciones
├── orquestador/SKILL.md       # Coordinador principal
├── requisitos/SKILL.md        # Análisis y categorización de requisitos
├── dev-back/SKILL.md          # Backend Laravel (PHP 8 / Laravel 13)
├── dev-front/SKILL.md         # Frontend Vue 3 (TypeScript / Vite)
├── dev-security/SKILL.md      # Auditoría de seguridad
└── qa/SKILL.md                # QA / pruebas automatizadas

opencode.json                  # Permisos de directorios externos + default_agent: dev-back
vms.json                       # IPs, usuarios, workspaces y rutas de agent-runner
pi-harness/                    # harness experimental de Pi, extensión y políticas por rol
proyectos/<slug>/              # salida: SOLICITUD.md, AGENT_RUNNER.md, *_output.log
tests/                         # pruebas aisladas con remoto Git y dobles de SSH/agent-runner
tools/                         # herramientas locales y bootstraps remotos en shell
```

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Agentes se definen en `skills/<nombre>/SKILL.md`** con YAML Frontmatter (`name`, `description`, `version`, `tools`).
- **Subagente `analista`**: cada agente tiene un `subagentes/analista.md` que valida dominio antes de ejecutar. Si emite `STATUS: RECHAZADO_FINAL`, el flujo se detiene.
- **Doble barrera de dominio**: `validar_y_despachar.sh` valida por regex en el script (capa determinista), y el `analista` del agente valida por interpretación (capa semántica).
- `despachar_vm.sh` inyecta `OPENAI_API_KEY` y `ANTHROPIC_API_KEY` en la sesión SSH remota si están disponibles en el entorno local.
- `provisionar_vm.sh` automatiza SSH, paquetes del sistema, NVM/Node, OpenCode, `agent-runner`, proyecto, dependencias y agente. `source_mode` controla si proyecto/runner vienen de Git o de la Mac; `agent_update_mode` controla independientemente si el agente se actualiza por Git/cron o por el monitor local.
- Con `agent_update_mode: local`, el monitor ejecuta `monitor_agentes_locales.sh`, calcula una versión por contenido y solo copia cuando cambia el agente. Con `agent_update_mode: git`, la VM consulta la rama publicada según `agent_poll_seconds`.
- `instalar_actualizacion_git.sh` instala un cron por rol que inicia cada minuto un ciclo de comprobaciones. El intervalo real se define con `agent_poll_seconds` en `vms.json` (10, 15, 20, 30 o 60 segundos). No requiere una sesión SSH abierta.
- `sincronizar_agente.sh` ejecuta inmediatamente el actualizador Git ya instalado en la VM; no usa `rsync` ni lee el agente local.
- La VM descarga `git_branch`, extrae únicamente `git_agent_path`, versiona por el identificador del árbol Git y activa `remote_agent/actual` mediante sustitución atómica de enlace simbólico.
- Los cambios locales solo llegan a las VMs después de `git commit` y `git push` a la rama configurada en `git_branch`; actualmente es `sincronizacion_agentes_git`.
- Si la sincronización o su validación falla, `agent-runner` no se ejecuta. No se reutiliza silenciosamente una versión anterior.
- El actualizador usa un bloqueo exclusivo y el despachador uno compartido; una activación nunca interrumpe una ejecución en curso.
- `validar_y_despachar.sh` crea un `.ejecucion_lock` en la carpeta del proyecto; un segundo despacho al mismo proyecto falla con error explícito.
- Cada despacho guarda `EVIDENCIA_AGENTES.md` dentro del proyecto con la VM, ruta resuelta, versión, commit, hash de `SKILL.md`, OpenCode, workspace, `run_id` y manifiesto remoto utilizados.
- La configuración de VMs se lee de `vms.json`. Las claves son perfiles de VM y `stack` indica el rol; esto permite perfiles adicionales como `backend-prueba` sin reemplazar `backend`.
- `opencode.json` permite acceso a directorios externos: `/home/serveradmin/laravel-dev/**`, `/home/serveradmin/vue-dev/**`, `/home/serveradmin/agentes/**`, `~/.local/state/agent-runner/runs/**`.
- **Solo `backend` y `frontend` se despachan vía tools/**. Los agentes `qa` y `dev-security` no tienen despacho automatizado; se definen pero no se invocan desde las herramientas actuales.
- **Pi todavía no forma parte del despacho**. `tools/provisionar_vm_pi.sh` puede preparar por separado una VM de prueba con Pi y Bubblewrap, pero no sustituye el despachador productivo. `pi-harness/` aplica la ejecución fail-closed: Linux selecciona Bubblewrap, macOS selecciona Seatbelt y Windows exige el adaptador `pi-appcontainer`. El flujo productivo continúa usando `agent-runner` hasta una etapa posterior.
- Si `provisionar_vm_pi.sh` recibe un perfil inexistente, solicita interactivamente IP, usuario, stack, fuentes y versiones, y lo agrega atómicamente a `vms.json`. La rama del agente usa como valor predeterminado la rama Git actual.

## Externalidades

- **Agent Runner** se ejecuta en VMs vía SSH; la ruta por defecto es `/home/serveradmin/.local/bin/agent-runner`.
- **VMs de desarrollo** (todas como `serveradmin`):
  - Backend: `192.168.50.193` → workspace `/home/serveradmin/laravel-dev`, agente `/home/serveradmin/agentes/backend`
  - Frontend: `192.168.50.40` → workspace `/home/serveradmin/vue-dev`, agente `/home/serveradmin/agentes/frontend`
  - QA: `192.168.50.63` → `/home/serveradmin/qa-dev`
- **Node en VMs**: `despachar_vm.sh` inyecta `PATH` con `/home/serveradmin/.nvm/versions/node/v24.19.0/bin`. Si la versión de Node cambia, actualizar la construcción de `REMOTE_CMD` en `tools/despachar_vm.sh`.
- **PHP en backend**: los perfiles declaran `php_version` y `php_min_version`. El provisionador instala PHP 8.4 desde `ppa:ondrej/php` cuando el Ubuntu LTS no ofrece una versión suficiente y valida el mínimo antes de Composer.

## Provisionamiento de una VM nueva

La guía operativa completa está en `PROVISIONAMIENTO_VM.md`.

1. Completar en `vms.json` el rol correspondiente: IP, usuario, workspace, repositorios y ramas del proyecto y de `agent-runner`, versiones de Node/OpenCode, ruta del agente e intervalo de consulta.
2. Si los repositorios son privados, exportar temporalmente un token de GitHub con acceso de lectura: `export GITHUB_TOKEN='...'`. El token viaja por la entrada estándar de SSH, se usa mediante un `GIT_ASKPASS` temporal y no se guarda en la VM.
3. Ejecutar `./tools/provisionar_vm.sh backend --con-sudo-interactivo` o `./tools/provisionar_vm.sh frontend --con-sudo-interactivo`. Se solicitará la contraseña `sudo` de la VM para instalar paquetes del sistema.
4. Comprobar posteriormente con `./tools/provisionar_vm.sh <rol> --solo-verificar`.

En ejecuciones normales posteriores se puede omitir `--con-sudo-interactivo` si todos los paquetes del sistema ya existen. Si un repositorio existente tiene cambios sin confirmar, el provisionador no hace `pull` ni borra esos cambios; informa la situación y continúa con el resto.
