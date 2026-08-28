# Harness experimental de Pi

Esta carpeta contiene el harness de ejecución de Pi usado por el despachador distribuido. El provisionador lo instala dentro de cada VM y `vms.json` selecciona un perfil Pi habilitado por stack.

## Qué hace

1. Detecta el sistema operativo real.
2. Selecciona una barrera compatible:
   - Linux: Bubblewrap (`bwrap`).
   - macOS: Seatbelt (`sandbox-exec`).
   - Windows: el adaptador `pi-appcontainer`.
3. Se detiene sin ejecutar Pi si la barrera esperada no existe o no corresponde al sistema operativo.
4. Carga la política del rol desde `policies/<rol>.json`.
5. Ejecuta Pi con un `HOME` temporal, sin descubrir instrucciones, extensiones o skills adicionales.
6. Carga únicamente el `SKILL.md` solicitado y la extensión de seguridad incluida en este directorio.
7. Guarda un manifiesto, el flujo de eventos JSONL, los errores y una auditoría de las herramientas utilizadas.

La extensión valida las herramientas `read`, `grep`, `find`, `ls`, `write` y `edit`. Las órdenes de `bash` o `powershell` se permiten solamente cuando el harness confirma que inició una barrera del sistema operativo. La barrera física sigue siendo la autoridad final frente a comandos indirectos o procesos hijos.

## Estado de los backends

- `bwrap`: implementado por el harness para Linux.
- `seatbelt`: implementado por el harness para macOS.
- `appcontainer`: definido mediante una interfaz externa estable. Hasta que exista el ejecutable nativo `pi-appcontainer`, Windows falla de forma segura y Pi no se inicia.

No se usa un contenedor de aplicaciones. Bubblewrap y Seatbelt crean aislamiento para el proceso de Pi directamente en el sistema anfitrión.

En distribuciones donde `/etc/resolv.conf` apunta a `/run/systemd/resolve`, el backend Linux monta en modo de solo lectura únicamente el directorio que contiene ese archivo para conservar DNS sin exponer el resto de `/run`.

## Uso local

Primero se comprueba el entorno sin ejecutar una tarea:

```bash
./tools/pi_harness.sh doctor \
  --role backend \
  --workspace /ruta/al/proyecto-laravel \
  --agent-dir ./skills/dev-back
```

Para revisar la selección y producir un manifiesto sin lanzar Pi:

```bash
./tools/pi_harness.sh start \
  --role backend \
  --workspace /ruta/al/proyecto-laravel \
  --agent-dir ./skills/dev-back \
  --task "Agrega una prueba para el endpoint de salud" \
  --dry-run
```

Para una ejecución real se quita `--dry-run`. Deben estar instalados `jq`, Pi (`@earendil-works/pi-coding-agent`) y la barrera de la plataforma. En Linux debe existir `bwrap`; en macOS, `sandbox-exec`.

Puede fijarse el proveedor y modelo por ejecución sin cambiar la configuración global de Pi:

```bash
./tools/pi_harness.sh start ... --provider openrouter --model cohere/north-mini-code:free
```

Los registros quedan por defecto en:

```text
~/.local/state/pi-harness/runs/<run_id>/manifest.json
~/.local/state/pi-harness/runs/<run_id>/tool-calls.jsonl
~/.local/state/pi-harness/runs/<run_id>/events.jsonl
~/.local/state/pi-harness/runs/<run_id>/stderr.log
```

Puede utilizarse `PI_HARNESS_RUNS_DIR` para elegir otro directorio de registros.

## Políticas

Las reglas admitidas son rutas exactas y directorios terminados en `/**`. Son relativas al workspace y no se permiten reglas absolutas ni recorridos con `..`.

Una ruta es accesible solo si aparece en la lista permitida correspondiente. Las listas `deny_read` y `deny_write` tienen prioridad. Además, la extensión resuelve enlaces simbólicos y rechaza los que salgan del workspace.

La política es una ayuda de mínimo privilegio, no una lista definitiva del proyecto. Antes de integrarla en las VMs habrá que validar con los repositorios reales qué directorios adicionales necesita cada agente.

## Siguiente etapa

`tools/provisionar_vm_pi.sh` instala Pi, este harness y Bubblewrap en una VM Linux. `tools/despachar_vm.sh` lo invoca por SSH; el harness carga el agente remoto y aplica la política del rol antes de ejecutar Pi.
