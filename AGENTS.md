# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido (shell scripts puros, sin Python). Coordina agentes especializados definidos en Markdown dentro de `skills/`. Ejecuta `agent-harness` sobre VMs remotas vía SSH.

## Comandos esenciales (`tools/`)

Secuencia obligatoria para ejecutar una tarea:

```bash
./tools/probar_vms.sh                                # 1. diagnosticar SSH a VMs
./tools/preparar_proyecto.sh "objetivo"               # 2. crear carpeta proyecto + SOLICITUD.md
./tools/validar_y_despachar.sh <rol> <dir> "tarea"    # 3. despacho con bloqueo físico de re-despacho
./tools/generar_reporte.sh <dir> "tarea"              # 4. consolidar reporte en AGENT_HARNESS.md
```

Utilidades auxiliares:

```bash
./tools/configurar_ssh_vm.sh user@ip                  # copiar llave SSH a VM nueva
./tools/despachar_vm.sh <rol> <dir> "tarea"           # despacho directo (sin lock; usar validar_y_despachar en su lugar)
```

## Estructura clave

```
skills/                        # Agentes y sus instrucciones
├── orquestador/SKILL.md       # Coordinador principal
├── requisitos/SKILL.md        # Análisis y categorización de requisitos
├── dev-back/SKILL.md          # Backend Laravel
├── dev-front/SKILL.md         # Frontend Vue 3
├── dev-security/SKILL.md      # Auditoría de seguridad
└── qa/SKILL.md                # QA / pruebas automatizadas

opencode.json                  # Permisos de directorios externos para OpenCode
vms.json                       # VMs y contrato de ejecución de agent-harness
proyectos/<slug>/              # salida: SOLICITUD.md, AGENT_HARNESS.md, *_output.jsonl
tools/                         # 6 herramientas bash ejecutables
```

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Agentes se definen en `skills/<nombre>/SKILL.md`** con YAML Frontmatter (`name`, `description`, `version`, `tools`).
- Cada agente tiene un subagente `analista` que valida dominio antes de ejecutar; si emite `RECHAZADO_FINAL`, el flujo se detiene.
- `despachar_vm.sh` usa `agent-harness run` y envía prompt/credenciales por STDIN cifrado. Las claves solo se autorizan con `--pass-env` cuando existen.
- `validar_y_despachar.sh` crea un lock atómico por rol en `.ejecucion_locks/`; permite backend y frontend en un mismo proyecto, pero bloquea duplicados del mismo rol.
- La configuración de VMs se lee de `vms.json`. Un rol con `enabled: false` no puede despacharse.
- La salida de cada VM es JSONL etiquetado y se consolida en `AGENT_HARNESS.md`.

## Externalidades

- **Agent Harness** se ejecuta en VMs vía SSH; la ruta por defecto es `/home/serveradmin/.local/bin/agent-harness`.
- **VMs de desarrollo**: backend en `192.168.50.193`, frontend en `192.168.50.40`, QA en `192.168.50.63` (todas como `serveradmin`).
- **Repos de trabajo en VMs**: `laravel-dev` y `vue-dev`.
- QA permanece deshabilitado hasta que `agent-harness` incorpore e instale `policies/qa.json`.
