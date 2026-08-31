# AGENTS.md — prueba_agentes

## Qué es este repo

Orquestador local distribuido (shell scripts puros, sin Python). Coordina agentes especializados definidos en Markdown dentro de `skills/`. Ejecuta Pi mediante `pi-harness` sobre VMs remotas vía SSH.

> **Nota sobre el README**: el `README.md` describe un sistema anterior basado en Python (`./bin/orquesta`, `runtime/orquestador.py`). La versión actual usa únicamente `tools/*.sh`. No sigas los comandos del README.

## Comandos esenciales (`tools/`)

Secuencia obligatoria para ejecutar una tarea:

```bash
./tools/orquestar.sh "objetivo"                       # entrada normal: clasifica y ejecuta todo el flujo
./tools/orquestar.sh --descomponer "objetivo"        # mostrar requisitos categorizados en JSON sin ejecutar
```

La secuencia interna, disponible también para diagnóstico manual, es:

```bash
./tools/probar_vms.sh                                # 1. diagnosticar SSH a VMs
./tools/preparar_proyecto.sh "objetivo"               # 2. crear carpeta proyecto + SOLICITUD.md
./tools/validar_y_despachar.sh <rol> <dir> "tarea"    # 3. despacho con bloqueo físico de re-despacho
./tools/generar_reporte.sh <dir> "tarea"              # 4. consolidar REPORTE_PI.md y la evidencia
```

Utilidades auxiliares:

```bash
./tools/orquestar.sh --clasificar "objetivo"          # mostrar el rol sin ejecutar agentes
./tools/descomponer_requisitos.sh "objetivo"          # dividir en requisitos backend/frontend/generales
./tools/clasificar_tarea.sh "objetivo"                # clasificador determinista directo
./tools/generar_evidencia_agente.sh <rol> <dir>       # evidencia del agente ejecutado en la VM
./tools/recolectar_contexto_memoria.sh "objetivo"      # tecnologías privadas + contratos compartidos
./tools/analizar_requisitos.sh "objetivo"              # asignar VM, repositorio y módulo exactos
./tools/agregar_repositorio_vm.sh ...                  # registrar/copiar otro módulo en una VM
./tools/configurar_perfil_backend_local.sh ...         # crear perfil core/módulo sin preguntas
./tools/limpiar_vm_pi.sh <perfil> --confirmar-limpieza # retirar artefactos administrados de una VM
./tools/configurar_ssh_vm.sh user@ip                  # copiar llave SSH a VM nueva
./tools/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo # preparar una VM Pi de extremo a extremo
./tools/provisionar_vm_pi.sh <perfil> --solo-verificar       # auditar una VM Pi sin reinstalar
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

vms.json                       # perfiles de VM, workspaces y configuración de Pi
pi-harness/                    # harness experimental de Pi, extensión y políticas por rol
proyectos/<slug>/              # salida: SOLICITUD.md, REPORTE_PI.md, *_output.log
tests/                         # pruebas aisladas con remoto Git y dobles de SSH/Pi
tools/                         # herramientas locales y bootstraps remotos en shell
```

## Convenciones importantes

- **Todo el contenido es en español** (archivos Markdown, outputs, mensajes de CLI).
- **Agentes se definen en `skills/<nombre>/SKILL.md`** con YAML Frontmatter (`name`, `description`, `version`, `tools`).
- **Subagente `analista`**: cada agente tiene un `subagentes/analista.md` que valida dominio antes de ejecutar. Si emite `STATUS: RECHAZADO_FINAL`, el flujo se detiene.
- **Doble barrera de dominio**: `validar_y_despachar.sh` valida por regex en el script (capa determinista), y el `analista` del agente valida por interpretación (capa semántica).
- `despachar_vm.sh` inyecta `OPENAI_API_KEY` y `ANTHROPIC_API_KEY` en la sesión SSH remota si están disponibles en el entorno local.
- `provisionar_vm_pi.sh` automatiza SSH, paquetes del sistema, NVM/Node, Pi, `pi-harness`, proyecto, dependencias y agente. `source_mode` controla si el proyecto viene de Git o de la Mac; `agent_update_mode` controla independientemente si el agente se actualiza por Git/cron o por el monitor local.
- Con `agent_update_mode: local`, el monitor ejecuta `monitor_agentes_locales.sh`, calcula una versión por contenido y solo copia cuando cambia el agente. Con `agent_update_mode: git`, la VM consulta la rama publicada según `agent_poll_seconds`.
- `instalar_actualizacion_git.sh` instala un cron por rol que inicia cada minuto un ciclo de comprobaciones. El intervalo real se define con `agent_poll_seconds` en `vms.json` (10, 15, 20, 30 o 60 segundos). No requiere una sesión SSH abierta.
- `sincronizar_agente.sh` ejecuta inmediatamente el actualizador Git ya instalado en la VM; no usa `rsync` ni lee el agente local.
- La VM descarga `git_branch`, extrae únicamente `git_agent_path`, versiona por el identificador del árbol Git y activa `remote_agent/actual` mediante sustitución atómica de enlace simbólico.
- Los cambios locales solo llegan a las VMs después de `git commit` y `git push` a la rama configurada en `git_branch`; actualmente es `sincronizacion_agentes_git`.
- Si la sincronización o su validación falla, Pi no se ejecuta. No se reutiliza silenciosamente una versión anterior.
- El actualizador usa un bloqueo exclusivo y el despachador uno compartido; una activación nunca interrumpe una ejecución en curso.
- `validar_y_despachar.sh` crea un candado por identificador de despacho; impide repetir el mismo destino sin bloquear módulos distintos que se ejecutan en paralelo.
- Cada despacho guarda `EVIDENCIA_AGENTES.md` dentro del proyecto con el perfil, VM, agente resuelto, versión, commit, hash de `SKILL.md`, Pi, workspace, `run_id` y manifiesto remoto utilizados.
- El Memory Gateway conserva SQLite/OpenAPI como fuente autoritativa e indexa el contexto semántico en Cognee OSS self-hosted mediante `add → cognify → search`; las VMs nunca se conectan directamente a Cognee.
- La configuración de VMs se lee de `vms.json`. Las claves son perfiles de VM y `stack` indica el rol; esto permite perfiles adicionales como `backend-prueba` sin reemplazar `backend`.
- Las políticas en `pi-harness/policies/*.json` limitan lectura y escritura por rol; el harness selecciona el aislamiento según el sistema operativo.
- **Solo `backend` y `frontend` se despachan vía tools/**. Los agentes `qa` y `dev-security` no tienen despacho automatizado; se definen pero no se invocan desde las herramientas actuales.
- `orquestar.sh` recolecta primero el inventario tecnológico privado y los contratos compartidos, después descompone la solicitud y asigna cada requisito a un perfil, repositorio y módulo exactos. Guarda sólo un resumen no sensible del contexto.
- Una solicitud que contiene requisitos backend y frontend se despacha automáticamente a ambos roles aunque el usuario no escriba explícitamente “Full-Stack”. `--clasificar` conserva la salida resumida `fullstack` y `--descomponer` muestra el detalle completo.
- **Pi es el único motor de despacho**. Puede haber múltiples perfiles backend y varios repositorios por perfil; el analista debe elegir un destino único o rechazar la solicitud como ambigua. `pi-harness/` aplica ejecución fail-closed: Linux selecciona Bubblewrap, macOS Seatbelt y Windows exige `pi-appcontainer`.
- Los grupos independientes por perfil/repositorio se lanzan en paralelo, incluso cuando todos son backend. El orquestador espera a todos y después consolida evidencia y reporte; si uno falla, igualmente espera a los demás y devuelve error.
- Si `provisionar_vm_pi.sh` recibe un perfil inexistente, solicita interactivamente IP, usuario, stack, fuentes y versiones, y lo agrega atómicamente a `vms.json`. La rama del agente usa como valor predeterminado la rama Git actual.

## Externalidades

- **Pi y pi-harness** viven en cada VM; la Mac únicamente clasifica, sincroniza el agente y envía la subtarea por SSH.
- **VMs de desarrollo**: se declaran únicamente en `vms.json`. Los perfiles backend y frontend eliminados deben recrearse mediante `tools/provisionar_vm_pi.sh` antes de utilizarlos.
- **Node en VMs**: `despachar_vm.sh` inyecta `PATH` con `/home/serveradmin/.nvm/versions/node/v24.19.0/bin`. Si la versión de Node cambia, actualizar la construcción de `REMOTE_CMD` en `tools/despachar_vm.sh`.
- **PHP en backend**: los perfiles declaran `php_version` y `php_min_version`. El provisionador instala PHP 8.4 desde `ppa:ondrej/php` cuando el Ubuntu LTS no ofrece una versión suficiente y valida el mínimo antes de Composer.

## Provisionamiento de una VM nueva

La guía operativa completa está consolidada en la sección **Provisionar una VM Pi** de `README.md`.

1. Crear el perfil con `tools/provisionar_vm_pi.sh`; guardará IP, usuario, workspace, stack, Pi, ruta del agente, rama e intervalo de consulta.
2. Si los repositorios son privados, exportar temporalmente un token de GitHub con acceso de lectura: `export GITHUB_TOKEN='...'`. El token viaja por la entrada estándar de SSH, se usa mediante un `GIT_ASKPASS` temporal y no se guarda en la VM.
3. Ejecutar `./tools/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo`. Se solicitará la contraseña `sudo` de la VM para instalar paquetes del sistema.
4. Comprobar posteriormente con `./tools/provisionar_vm_pi.sh <perfil> --solo-verificar`.

En ejecuciones normales posteriores se puede omitir `--con-sudo-interactivo` si todos los paquetes del sistema ya existen. Si un repositorio existente tiene cambios sin confirmar, el provisionador no hace `pull` ni borra esos cambios; informa la situación y continúa con el resto.
