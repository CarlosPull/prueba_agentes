#!/usr/bin/env bash
# Se invoca después de migraciones/API. Sin socket Podman dentro de los servicios.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
private="$ROOT/.private/plataforma"
image=localhost/orquestador-plataforma:0.1
mkdir -p "$private/provision/profiles" "$private/public" "$private/execution"
for key in provision execution; do
  if [ ! -e "$private/provision/${key}_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "orquestador-$key" -f "$private/provision/${key}_ed25519"
  fi
done
cp "$private/provision/provision_ed25519.pub" "$private/public/"
cp "$private/provision/execution_ed25519" "$private/execution/"
chmod 600 "$private/provision/"*ed25519 "$private/execution/"*ed25519
for volume in orquestador-provision-secrets orquestador-execution-secrets orquestador-public orquestador-registry orquestador-runs; do
  podman volume exists "$volume" || podman volume create "$volume" >/dev/null
done
# Copia a volúmenes administrados; no depende del mapeo UID del host para bind mounts.
copy_private() {
  tar -cf - -C "$1" . | podman run --rm -i --user 0:0 --network none --volume "$2:/dest" "$image" \
    sh -c 'umask 077; tar -xf - -C /dest; chown -R 1000:1000 /dest; chmod 700 /dest'
}
copy_private "$private/provision" orquestador-provision-secrets
copy_private "$private/execution" orquestador-execution-secrets
copy_private "$private/public" orquestador-public
podman run --rm --user 0:0 --network none --volume orquestador-registry:/registry --volume orquestador-runs:/runs "$image" sh -c 'chown 1000:1000 /registry /runs; chmod 700 /registry /runs'
podman run --replace -d --name orquestador-preparacion --pod orquestador-plataforma --env-file "$private/api.env" \
  --env PROVISION_PRIVATE=/run/orquestador/secrets --env WORKER_REGISTRY=/var/lib/orquestador/registry \
  --volume orquestador-provision-secrets:/run/orquestador/secrets:ro --volume orquestador-registry:/var/lib/orquestador/registry \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges --tmpfs /tmp:rw,nosuid,size=128m \
  "$image" node dist/provision-main.js >/dev/null
podman run --replace -d --name orquestador-trabajador --pod orquestador-plataforma --env-file "$private/api.env" \
  --env WORKER_REGISTRY=/var/lib/orquestador/registry --env WORKER_RUNS=/var/lib/orquestador/runs \
  --volume orquestador-execution-secrets:/run/orquestador/secrets:ro --volume orquestador-registry:/var/lib/orquestador/registry:ro --volume orquestador-runs:/var/lib/orquestador/runs \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges --tmpfs /tmp:rw,nosuid,size=128m \
  "$image" node dist/worker-main.js >/dev/null
echo 'Servicios de preparación y ejecución iniciados. La web muestra sus latidos.'
