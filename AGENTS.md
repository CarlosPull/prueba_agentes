# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido y ultraliviano (100% modular mediante herramientas en `tools/`, sin Python ni wrappers bin). Coordina agentes especializados definidos en Markdown dentro de la carpeta `skills/`.

## Comandos esenciales (Herramientas en `tools/`)

```bash
./tools/probar_vms.sh                          # diagnosticar SSH a VMs
./tools/preparar_proyecto.sh "objetivo"         # inicializar carpeta del proyecto
./tools/despachar_vm.sh <rol> <dir> "objetivo"  # despachar a una VM por SSH
./tools/generar_reporte.sh <dir> "objetivo"     # consolidar reporte final
```

## Estructura clave

```
skills/<nombre>/SKILL.md      # reglas, misión y habilidades del agente (ej: dev-back, dev-front, qa)
opencode.json                 # configuración nativa de OpenCode y permisos
vms.json                      # IPs, usuarios, workspaces y rutas del agent-runner
orquestador/ORQUESTADOR.md    # flujo de orquestación e instrucciones de invocación de herramientas
proyectos/<nombre>/           # salida: SOLICITUD.md, AGENT_RUNNER.md, logs
tools/                        # directorio de las 4 herramientas modulares ejecutables
```

## Agentes disponibles

| Agente | Rol | Tecnologías |
|--------|-----|-------------|
| `dev-back` | Backend con subagentes (generador-codigo, qa, documentador) | PHP 8, Laravel |
| `dev-front` | Frontend con subagente (generador-ui) | Vue 3, TypeScript, Vite |
| `qa` | Genera tests sobre código generado | Unitarias, integración, APIs |

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Los agentes se definen en Markdown** dentro de `skills/<nombre>/SKILL.md`.
- `tools/despachar_vm.sh` inyecta automáticamente la `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` en la sesión SSH remota.

## Externalidades

- **Agent Runner** se ubica en `/home/serveradmin/.local/bin/agent-runner` dentro de las VMs.
- **VMs de desarrollo**: configuradas dinámicamente en `vms.json`.
- **Repos de trabajo**: `laravel-dev` y `vue-dev` en las VMs.
