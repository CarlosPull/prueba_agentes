# Orquestador distribuido de agentes

Orquestador local escrito en Bash que clasifica tareas por rol y ejecuta
`agent-harness` dentro de máquinas virtuales Linux conectadas mediante SSH.

El orquestador decide **qué rol** debe trabajar y compone sus instrucciones.
Agent Harness decide **qué puede leer y escribir** ese rol mediante una política
aplicada con Bubblewrap.

## Requisitos locales

- Bash.
- `jq`.
- Cliente OpenSSH y autenticación por llave hacia las VMs.

## Requisitos en cada VM

- Python 3.10 o posterior.
- `agent-harness` instalado mediante `uv tool install --force .`.
- OpenCode o Codex autenticado.
- Bubblewrap (`bwrap`).
- Una política instalada para el valor `policy_role` de `vms.json`.

Comprueba el entorno remoto con:

```bash
./tools/probar_vms.sh
```

El diagnóstico falla con código distinto de cero si una VM habilitada no tiene
SSH, el binario, el motor o el sandbox listos.

## Configuración

Cada entrada de `vms.json` representa un rol del orquestador:

```json
{
  "backend": {
    "enabled": true,
    "ip": "192.168.50.193",
    "user": "serveradmin",
    "workspace": "/home/serveradmin/laravel-dev",
    "harness_bin": "/home/serveradmin/.local/bin/agent-harness",
    "engine_bin_dir": "/home/serveradmin/.nvm/versions/node/v24.19.0/bin",
    "engine": "opencode",
    "agent": "build",
    "skill": "dev-back",
    "policy_role": "backend",
    "sandbox": "bwrap",
    "credentials": "auto",
    "output": "jsonl"
  }
}
```

- `agent` es el perfil de OpenCode. `build` funciona sin crear un perfil por rol.
- `engine_bin_dir` añade al `PATH` remoto el directorio donde vive OpenCode.
- `skill` selecciona la carpeta local `skills/<nombre>/` usada para el prompt.
- `policy_role` selecciona `policies/<rol>.json` dentro de Agent Harness.
- `credentials` admite `auto`, `required` o `none`.
- Los roles sin una política instalada deben permanecer con `enabled: false`.

QA está declarado, pero deshabilitado hasta instalar `policies/qa.json` en Agent
Harness.

## Flujo de uso

```bash
# 1. Verificar todas las VMs habilitadas.
./tools/probar_vms.sh

# 2. Crear la carpeta auditable del proyecto.
DIR=$(./tools/preparar_proyecto.sh "Implementar API y pantalla de perfil")

# 3. Despachar uno o varios roles.
./tools/validar_y_despachar.sh backend "$DIR" "Implementar API de perfil"
./tools/validar_y_despachar.sh frontend "$DIR" "Implementar pantalla de perfil"

# 4. Consolidar los eventos devueltos.
./tools/generar_reporte.sh "$DIR" "Implementar API y pantalla de perfil"
```

El lock se mantiene por rol en `.ejecucion_locks/<rol>`. Esto permite ejecutar
backend y frontend en el mismo proyecto, pero evita duplicar accidentalmente un
despacho. Si SSH o Agent Harness falla, el lock se libera para permitir un
reintento explícito.

## Prompt y habilidades

`despachar_vm.sh` compone el prompt con:

1. `skills/<rol>/SKILL.md`.
2. `skills/<rol>/subagentes/analista.md`, cuando existe.
3. `skills/<rol>/memory.md`, cuando existe.
4. Los demás subagentes y referencias Markdown del skill.
5. La tarea solicitada.

El prompt y las claves opcionales viajan dentro del canal SSH por STDIN, no en
los argumentos del proceso SSH. Si existen `OPENAI_API_KEY` o
`ANTHROPIC_API_KEY`, se autorizan explícitamente mediante `--pass-env`. La opción
preferida para operación estable es autenticar el motor dentro de cada VM y usar
`credentials: required`.

## Salidas

Por cada rol se crean:

```text
<rol>_output.jsonl    # eventos estructurados de Agent Harness
<rol>_error.log       # errores SSH o fallos previos al stream del harness
<rol>_dispatch.json   # código de salida del transporte
```

`generar_reporte.sh` interpreta `run.finished`, el estado del harness y el código
SSH, y produce:

```text
AGENT_HARNESS.md
```

Los manifiestos completos permanecen en la VM bajo
`~/.local/state/agent-harness/runs/<run_id>/manifest.json`.

## Actualizar Agent Harness en las VMs

Después de actualizar su repositorio o modificar políticas:

```bash
cd /ruta/al/repositorio/agent-runner
git pull
uv tool install --force .
agent-harness doctor --engine opencode
```

Las políticas forman parte del paquete instalado; editar el repositorio sin
reinstalar no actualiza el comportamiento del ejecutable.
