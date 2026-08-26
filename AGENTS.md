# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido (shell scripts puros, sin Python). Coordina agentes especializados definidos en Markdown dentro de `skills/`. Ejecuta `agent-runner` sobre VMs remotas vía SSH.

> **Nota sobre el README**: el `README.md` describe un sistema anterior basado en Python (`./bin/orquesta`, `runtime/orquestador.py`). La versión actual usa únicamente `tools/*.sh`. No sigas los comandos del README.

## Comandos esenciales (`tools/`)

Secuencia obligatoria para ejecutar una tarea:

```bash
./tools/probar_vms.sh                                # 1. diagnosticar SSH a VMs
./tools/preparar_proyecto.sh "objetivo"               # 2. crear carpeta proyecto + SOLICITUD.md
./tools/validar_y_despachar.sh <rol> <dir> "tarea"    # 3. despacho con bloqueo físico de re-despacho
./tools/generar_reporte.sh <dir> "tarea"              # 4. consolidar reporte en AGENT_RUNNER.md
```

Utilidades auxiliares:

```bash
./tools/configurar_ssh_vm.sh user@ip                  # copiar llave SSH a VM nueva
./tools/despachar_vm.sh <rol> <dir> "tarea"           # despacho directo (sin lock; usar validar_y_despachar en su lugar)
```

> **Importante**: `despachar_vm.sh` busca skill files en este orden:
> `skills/dev-<rol>/SKILL.md` → `skills/<rol>/SKILL.md` → `skills/<rol>/AGENTE.md`.
> El contenido del SKILL.md se inyecta como prompt del agente remoto.

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
proyectos/<slug>/              # salida: SOLICITUD.md, AGENT_RUNNER.md, *_output.log
tools/                         # 6 herramientas bash ejecutables
```

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Agentes se definen en `skills/<nombre>/SKILL.md`** con YAML Frontmatter (`name`, `description`, `version`, `tools`).
- **Subagente `analista`**: cada agente tiene un `subagentes/analista.md` que valida dominio antes de ejecutar. Si emite `STATUS: RECHAZADO_FINAL`, el flujo se detiene.
- **Doble barrera de dominio**: `validar_y_despachar.sh` valida por regex en el script (capa determinista), y el `analista` del agente valida por interpretación (capa semántica).
- `despachar_vm.sh` inyecta `OPENAI_API_KEY` y `ANTHROPIC_API_KEY` en la sesión SSH remota si están disponibles en el entorno local.
- `validar_y_despachar.sh` crea un `.ejecucion_lock` en la carpeta del proyecto; un segundo despacho al mismo proyecto falla con error explícito.
- La configuración de VMs se lee de `vms.json` (roles: `backend`, `frontend`, `qa`).
- `opencode.json` permite acceso a directorios externos: `/home/serveradmin/laravel-dev/**`, `/home/serveradmin/vue-dev/**`, `~/.local/state/agent-runner/runs/**`.
- **Solo `backend` y `frontend` se despachan vía tools/**. Los agentes `qa` y `dev-security` no tienen despacho automatizado; se definen pero no se invocan desde las herramientas actuales.

## Externalidades

- **Agent Runner** se ejecuta en VMs vía SSH; la ruta por defecto es `/home/serveradmin/.local/bin/agent-runner`.
- **VMs de desarrollo** (todas como `serveradmin`):
  - Backend: `192.168.50.193` → `/home/serveradmin/laravel-dev`
  - Frontend: `192.168.50.40` → `/home/serveradmin/vue-dev`
  - QA: `192.168.50.63` → `/home/serveradmin/qa-dev`
- **Node en VMs**: `despachar_vm.sh` inyecta `PATH` con `/home/serveradmin/.nvm/versions/node/v24.19.0/bin`. Si la versión de Node cambia, actualizar la línea `ENV_EXPORTS` en `tools/despachar_vm.sh`.
