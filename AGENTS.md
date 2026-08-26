# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido y ultraliviano (100% modular mediante herramientas en `tools/`, sin Python ni wrappers bin). Coordina agentes especializados definidos en Markdown dentro de la carpeta `skills/`.

## Comandos esenciales (Herramientas en `tools/`)

```bash
./tools/probar_vms.sh                          # diagnosticar SSH a VMs
./tools/configurar_ssh_vm.sh user@ip           # automatizar llave SSH hacia una nueva VM
./tools/preparar_proyecto.sh "objetivo"         # inicializar carpeta del proyecto
./tools/despachar_vm.sh <rol> <dir> "objetivo"  # despachar a una VM por SSH
./tools/generar_reporte.sh <dir> "objetivo"     # consolidar reporte final
```


## Estructura clave

```
skills/                        # Carpeta ÚNICA con TODAS las habilidades y agentes
├── orquestador/SKILL.md       # Reglas del Orquestador principal
├── dev-back/SKILL.md          # Especialista Backend Laravel
├── dev-front/SKILL.md         # Especialista Frontend Vue 3
├── dev-security/SKILL.md      # Auditoría de Seguridad
└── qa/SKILL.md                # Aseguramiento de Calidad

opencode.json                  # Configuración nativa de OpenCode y permisos
vms.json                       # IPs, usuarios, workspaces y rutas del agent-runner
proyectos/<nombre>/            # salida: SOLICITUD.md, AGENT_RUNNER.md, logs
tools/                         # directorio de las 4 herramientas modulares ejecutables
```

## Agentes disponibles en `skills/`

| Agente / Skill | Rol | Tecnologías |
| :--- | :--- | :--- |
| `orquestador` | Coordinador principal del flujo de trabajo | Bash, SSH, tools/ |
| `dev-back` | Backend con subagentes | PHP 8, Laravel 13 |
| `dev-front` | Frontend con subagentes | Vue 3, TypeScript, Vite |
| `dev-security` | Auditoría de vulnerabilidades y seguridad | OWASP, Sanctum, SQL |
| `qa` | Genera tests sobre código generado | PHPUnit, Vitest |

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Todos los agentes se definen dentro de `skills/<nombre>/SKILL.md`** con encabezado YAML Frontmatter.
- `tools/despachar_vm.sh` inyecta automáticamente la `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` en la sesión SSH remota.

## Externalidades

- **Agent Runner** se ubica en `/home/serveradmin/.local/bin/agent-runner` dentro de las VMs.
- **VMs de desarrollo**: configuradas dinámicamente en `vms.json`.
- **Repos de trabajo**: `laravel-dev` y `vue-dev` en las VMs.
