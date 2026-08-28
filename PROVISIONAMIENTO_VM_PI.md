# Provisionamiento inicial de una VM con Pi

`tools/provisionar_vm_pi.sh` prepara una VM Linux nueva para ejecutar los agentes con Pi y `pi-harness`. Este es el runtime del flujo principal; no instala ni copia Agent Runner u OpenCode.

## Qué instala

1. Configura la llave SSH de la Mac si la VM todavía solicita contraseña SSH.
2. Instala paquetes del sistema, `jq`, cron y Bubblewrap.
3. Para backend instala PHP y Composer con las versiones del perfil.
4. Instala NVM y la versión de Node declarada en `vms.json`.
5. Instala Pi desde el paquete `@earendil-works/pi-coding-agent`.
6. Copia `pi-harness` a `~/.local/lib/prueba-agentes/pi-harness` y crea `~/.local/bin/pi-harness`.
7. Clona o copia el proyecto según `source_mode` e instala sus dependencias.
8. Instala el agente desde Git/cron o desde la Mac según `agent_update_mode`.
9. Comprueba Pi, el harness, la política, el agente activo y que Bubblewrap pueda crear realmente un sandbox.

En Ubuntu utiliza primero el perfil oficial `/etc/apparmor.d/bwrap-userns-restrict` cuando el paquete AppArmor lo proporciona (incluido Ubuntu 26.04). Solo en sistemas que no lo incluyen instala el perfil de compatibilidad dirigido a `/usr/bin/bwrap`. No desactiva AppArmor ni cambia globalmente los controles `kernel.apparmor_restrict_unprivileged_*`.

El mismo perfil queda disponible para el despachador del orquestador. Si hay otro perfil habilitado para el mismo stack, debe dejarse `dispatch_enabled: false` en uno de ellos.

## Configuración automática de `vms.json`

No es necesario crear manualmente el perfil. Cuando el nombre recibido no existe, el mismo provisionador pregunta los datos de la VM, el proyecto y el agente, guarda el perfil de forma atómica en `vms.json` y continúa con la instalación.

Para configurar y provisionar en una sola ejecución:

```bash
./tools/provisionar_vm_pi.sh backend-pi-prueba --con-sudo-interactivo
```

Para guardar solamente el perfil sin abrir una conexión SSH:

```bash
./tools/provisionar_vm_pi.sh backend-pi-prueba --solo-configurar
```

La rama de agentes propuesta por defecto es la rama actual del orquestador.

### Campos guardados

Se reutilizan los mismos campos de proyecto y agente:

- `ip`, `user`, `workspace` y `stack`.
- `source_mode`: `git` o `local`.
- `project_git_url` y `project_git_branch` para Git.
- `project_local_path` para copia desde la Mac.
- `node_version`.
- `php_version` y `php_min_version` para backend.
- `install_dependencies`.
- `local_agent` y `remote_agent`.
- `agent_update_mode`, `git_url`, `git_branch`, `git_agent_path` y `agent_poll_seconds`.

Puede agregarse opcionalmente:

```json
"pi_version": "latest"
```

Si se omite, se utiliza `latest`. Para instalaciones reproducibles es preferible colocar una versión exacta, por ejemplo `1.2.3`, después de confirmar la versión que se desea probar.

El perfil se registra con `engine: "pi"` y permanece con `dispatch_enabled: false` durante la instalación. Solo después de verificar correctamente la VM cambia a `true` y deshabilita otros perfiles Pi del mismo stack; así el orquestador siempre selecciona una única VM lista.

Con `source_mode: local`, el workspace remoto se sincroniza como espejo del proyecto de la Mac. Se eliminan archivos remotos que ya no existen en la fuente para evitar configuraciones obsoletas; `.git`, `.env`, `vendor` y `node_modules` quedan excluidos de esa eliminación y se administran dentro de la VM.

## Primera ejecución

Para una VM backend completamente nueva:

```bash
./tools/provisionar_vm_pi.sh <perfil-vm> --con-sudo-interactivo
```

Si `backend-pi-prueba` todavía no existe, el script lo creará; no reemplaza `backend` ni `backend-prueba`.

La primera conexión puede solicitar la contraseña del usuario remoto para registrar la llave SSH. Después solicitará la contraseña `sudo` de esa misma VM para instalar los paquetes. Debe utilizarse la contraseña actual del usuario de Ubuntu.

Si el proyecto se obtiene de un repositorio privado con `source_mode: git`:

```bash
export GITHUB_TOKEN='token-de-solo-lectura'
./tools/provisionar_vm_pi.sh <perfil-vm> --con-sudo-interactivo
unset GITHUB_TOKEN
```

El token se utiliza de forma temporal y no se almacena en la VM. Con `source_mode: local` no es necesario.

## Verificación posterior

```bash
./tools/provisionar_vm_pi.sh <perfil-vm> --solo-verificar
```

Dentro de la VM también puede ejecutarse:

```bash
~/.local/bin/pi-harness doctor \
  --role backend \
  --workspace /home/usuario/laravel-dev \
  --agent-dir /home/usuario/agentes/backend/actual
```

La respuesta debe terminar con `Resultado: LISTO`.

## Autenticación del modelo

El provisionador instala Pi, pero el inicio de sesión se realiza una vez de forma interactiva dentro de cada VM. Para el proveedor configurado por defecto (`openai-codex`):

```bash
ssh usuario@ip-de-la-vm
export PATH="$HOME/.nvm/versions/node/v24.19.0/bin:$HOME/.local/bin:$PATH"
pi
```

Dentro de Pi selecciona el inicio de sesión de OpenAI/Codex. La sesión queda en `~/.pi/agent/auth.json`; `pi-harness` la monta dentro del entorno aislado sin copiarla al proyecto. `tools/probar_vms.sh` exige esa sesión antes de permitir un despacho.
