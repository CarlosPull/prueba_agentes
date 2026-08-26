# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido y ultraliviano (100% Shell/Bash, sin Python). Coordina agentes especializados definidos en Markdown dentro de la carpeta `skills/`.

## Comandos esenciales

```bash
./bin/orquesta probar-vms                       # diagnosticar SSH a VMs
./bin/orquesta "Descripción del objetivo"        # orquestación distribuida en paralelo
```

El ejecutable `bin/orquesta` es un wrapper directo que enruta todo a `bin/orquestar_vms.sh`.

## Estructura clave

```
skills/<nombre>/SKILL.md      # reglas, misión y habilidades del agente (ej: dev-back, dev-front, qa)
opencode.json                 # configuración nativa de OpenCode y permisos
proyectos/<nombre>/           # salida: SOLICITUD.md, AGENT_RUNNER.md, logs
bin/orquesta                  # ejecutable principal
bin/orquestar_vms.sh          # script de despacho SSH paralelo a las VMs
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
- `bin/orquestar_vms.sh` inyecta automáticamente la `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` en la sesión SSH remota.

## Externalidades

- **Agent Runner** se ubica en `/home/serveradmin/.local/bin/agent-runner` dentro de las VMs.
- **VMs de desarrollo**: backend en `192.168.50.193`, frontend en `192.168.50.40`.
- **Repos de trabajo**: `laravel-dev` y `vue-dev` en las VMs.
