# Provisionamiento automatizado de VMs

El comando `tools/provisionar_vm.sh` prepara una VM nueva de backend o frontend usando `vms.json` como única fuente de configuración. Cada clave de primer nivel es un perfil de VM y su campo `stack` determina el rol del agente, por lo que pueden existir varios perfiles backend sin reemplazarse. Puede ejecutarse varias veces: instala lo que falta, actualiza repositorios limpios y nunca descarta cambios Git locales.

## Qué automatiza

1. Comprueba la conexión SSH y, si hace falta, invoca `configurar_ssh_vm.sh` para instalar la llave pública de la Mac.
2. Con `--con-sudo-interactivo`, instala paquetes base, activa `cron` y agrega los paquetes del stack.
3. Instala NVM, la versión declarada de Node y la versión fijada de OpenCode.
4. Según `source_mode`, clona desde Git o copia desde la Mac `agent-runner`, y lo instala con `pip` para el usuario remoto.
5. Clona o copia el proyecto Laravel/Vue y, si `install_dependencies` es `true`, instala sus dependencias.
6. Según `agent_update_mode`, instala el cron Git subminuto en la VM o un LaunchAgent de sincronización local en la Mac.
7. Audita repositorios, origins, ramas, ejecutables, agente activo, cron y `agent-runner doctor`.

La instalación de paquetes del sistema es la única fase que necesita la contraseña `sudo` de la VM. El resto se instala dentro de `/home/<usuario>`.

## Configuración

Cada rol automatizado de `vms.json` contiene:

- `ip`, `user` y `workspace`: destino SSH y directorio del proyecto.
- `stack`: `backend` o `frontend`.
- `source_mode`: `git` para clonar repositorios o `local` para copiarlos desde la Mac mediante SSH/rsync.
- `agent_update_mode`: `git` para que la VM descargue agentes después del push, o `local` para copiarlos desde la Mac.
- `project_local_path` y `agent_runner_local_path`: fuentes de la Mac cuando se utiliza `source_mode: local`.
- `project_git_url` y `project_git_branch`: repositorio y rama del proyecto.
- `agent_runner`, `agent_runner_git_url` y `agent_runner_git_branch`: instalación de `agent-runner`.
- `node_version` y `opencode_version`: versiones reproducibles del runtime.
- `php_version` y `php_min_version`: versión PHP instalada y mínimo aceptado para perfiles backend.
- `install_dependencies`: habilita `composer install` o `npm ci`.
- `remote_agent`: directorio persistente del agente en la VM.
- `git_url`, `git_branch` y `git_agent_path`: fuente exacta de las instrucciones del agente.
- `agent_poll_seconds`: intervalo permitido de 10, 15, 20, 30 o 60 segundos.

Por ejemplo, `backend` apunta a la VM estable con Git. `backend-prueba` usa `source_mode: local` para copiar Laravel y `agent-runner`, pero `agent_update_mode: git` para que la VM descargue `skills/dev-back` desde la rama publicada. El provisionador recibe el perfil: `./tools/provisionar_vm.sh backend-prueba --con-sudo-interactivo`.

En la primera ejecución, el mismo comando comprueba la llave SSH de la Mac. Si todavía no está autorizada, invoca `configurar_ssh_vm.sh`: solicita una sola vez la contraseña del usuario remoto, agrega la llave pública a `authorized_keys` y deja las conexiones posteriores sin contraseña SSH. La contraseña `sudo` continúa siendo necesaria para instalar paquetes del sistema.

Para cambiar de rama no se edita el cron manualmente: se modifica la rama correspondiente en `vms.json` y se vuelve a ejecutar el provisionador o `tools/instalar_actualizacion_git.sh <rol>`.

## Primera instalación

Si los repositorios del proyecto o de `agent-runner` son privados, define temporalmente `GITHUB_TOKEN` con permiso de lectura. El token se envía por la entrada estándar de SSH, se utiliza con un archivo `GIT_ASKPASS` temporal y no queda almacenado en la VM.

Esta sección aplica únicamente a perfiles con `source_mode: git`. Los perfiles locales, como `backend-prueba`, no necesitan token ni acceso de la VM a los repositorios privados.

### Instalación desde fuentes locales

Con `backend-prueba` basta ejecutar desde la Mac:

```bash
./tools/provisionar_vm.sh backend-prueba --con-sudo-interactivo
```

El perfil copia actualmente `/Users/carlos/Documents/GitHub/laravel-dev`, `/Users/carlos/Documents/GitHub/agent-runner` y `skills/dev-back`. Antes de conectarse valida que las fuentes contengan `composer.json`, `artisan`, `pyproject.toml` y `SKILL.md`. Se excluyen `.git`, entornos virtuales, `vendor`, `node_modules` y `.env`; las dependencias se reconstruyen dentro de Ubuntu para no trasladar binarios de macOS ni secretos locales.

Para Laravel 13, `backend-prueba` declara PHP 8.4 con mínimo 8.4.1. Si Ubuntu trae una versión anterior, el provisionador agrega `ppa:ondrej/php` únicamente en versiones Ubuntu LTS compatibles, instala las extensiones 8.4 y valida el runtime antes de ejecutar Composer. El bootstrap usa `C.UTF-8` para evitar que variables de locale heredadas desde macOS generen advertencias.

En `backend-prueba`, la copia inicial del proyecto es local, pero la actualización del agente es Git: después de `commit` y `push` a `sincronizacion_agentes_git`, el cron de la VM consulta el repositorio público y activa `skills/dev-back` en un máximo aproximado de 30 segundos. La VM puede hacerlo aunque la Mac se apague después del push.

Para otros perfiles con `agent_update_mode: local`, `instalar_monitor_local.sh` registra `com.prueba-agentes.sincronizacion-local` en `~/Library/LaunchAgents`. Cada 30 segundos copia y activa los cambios locales; en ese modo la Mac debe permanecer encendida.

La consulta Git inmediata de `backend-prueba` puede probarse con:

```bash
./tools/sincronizar_agente.sh backend-prueba
```

Los logs del monitor quedan en `~/Library/Logs/prueba-agentes/`.

```bash
export GITHUB_TOKEN='token-con-acceso-de-lectura'
./tools/provisionar_vm.sh backend --con-sudo-interactivo
unset GITHUB_TOKEN
```

Para frontend:

```bash
export GITHUB_TOKEN='token-con-acceso-de-lectura'
./tools/provisionar_vm.sh frontend --con-sudo-interactivo
unset GITHUB_TOKEN
```

Durante la primera conexión puede solicitarse la contraseña SSH para copiar la llave. Durante la instalación de paquetes se solicitará la contraseña `sudo`.

## Reejecución y auditoría

Cuando la VM ya tiene los paquetes del sistema:

```bash
./tools/provisionar_vm.sh backend
```

Para comprobar el estado sin instalar, clonar ni hacer `pull`:

```bash
./tools/provisionar_vm.sh backend --solo-verificar
./tools/provisionar_vm.sh frontend --solo-verificar
```

Si un repositorio existente tiene un `origin` distinto, la ejecución falla para evitar actualizar el proyecto equivocado. Si tiene cambios locales, informa el caso y no cambia de rama ni ejecuta `pull` sobre ese repositorio.

## Pruebas locales

```bash
./tests/probar_automatizacion.sh
```

Esta prueba crea un remoto Git aislado y comprueba la descarga, activación atómica, aislamiento por rol, despacho y ciclo subminuto sin modificar las VMs reales.

## Archivos instalados en cada VM

Para backend, por ejemplo:

```text
/home/serveradmin/.local/lib/prueba-agentes/provisionar_vm.sh
/home/serveradmin/agentes/backend/actualizar_desde_git.sh
/home/serveradmin/agentes/backend/ciclo_actualizacion_git.sh
/home/serveradmin/agentes/backend/git-agent.conf
/home/serveradmin/agentes/backend/actual -> .versiones/<id-del-arbol-git>
/home/serveradmin/agentes/backend/actualizaciones.log
```

El cron del usuario se consulta con `crontab -l`. Cada minuto inicia `ciclo_actualizacion_git.sh`; ese ciclo ejecuta las comprobaciones internas según `agent_poll_seconds`, por lo que no es necesario editar cron para trabajar en segundos.
