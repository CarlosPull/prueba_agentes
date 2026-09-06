#!/usr/bin/env bash
# Auditoría local sin API keys ni invocaciones de modelos. No habilita destinos.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=localhost/orquestador-modulo-prueba:0.1
name="orquestador-aislamiento-$$"
volume="$name-codigo"
cleanup() { podman rm -f "$name" >/dev/null 2>&1 || true; podman volume rm "$volume" >/dev/null 2>&1 || true; }
trap cleanup EXIT
podman build --target frontend -t "$image" -f "$ROOT/plataforma/Containerfile.modulo" "$ROOT"
podman volume create "$volume" >/dev/null
podman run --rm --volume "$volume:/workspace" --user 0:0 "$image" sh -c 'mkdir -p /workspace/repositorio/src; chown -R 1000:1000 /workspace' 
podman run -d --name "$name" --read-only --user 1000:1000 --cap-drop=ALL \
  --security-opt=no-new-privileges --network none --pids-limit 256 --memory 512m \
  --tmpfs /tmp:rw,nosuid,size=128m --volume "$volume:/workspace" "$image" >/dev/null
podman exec "$name" sh -c 'printf "prueba\n" > /workspace/repositorio/src/permitido.txt'
if podman exec "$name" sh -c 'touch /etc/no-permitido' >/dev/null 2>&1; then echo 'FALLO: el sistema raíz permite escritura.' >&2; exit 1; fi
podman exec "$name" sh -c 'test ! -e /run/podman/podman.sock && test ! -e /var/run/docker.sock'
# doctor comprueba binarios; esta ejecución adicional comprueba namespaces efectivos.
podman exec "$name" /opt/pi-harness/bin/pi-harness doctor --role frontend --workspace /workspace/repositorio --agent-dir /opt/agente/actual --json
if ! podman exec "$name" bwrap --unshare-all --die-with-parent --ro-bind / / --proc /proc --dev /dev /bin/true; then
  echo 'AISLAMIENTO_PENDIENTE: el host no permite Bubblewrap dentro de este contenedor. No habilitar destinos ni usar modo privilegiado.' >&2
  exit 4
fi
echo '✓ Raíz de solo lectura, ausencia de sockets y namespaces anidados comprobados. Falta el piloto completo de Pi/SSH.'
