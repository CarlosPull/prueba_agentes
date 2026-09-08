#!/usr/bin/env bash
# Construye y verifica el contenedor rootless que ejecuta Pi para un repositorio.
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

MODO="${1:-provisionar}"
[ "$MODO" = "provisionar" ] || [ "$MODO" = "verificar" ] || {
  echo "Error: modo de contenedor no válido: '$MODO'." >&2
  exit 1
}

IFS= read -r PROFILE
IFS= read -r STACK
IFS= read -r REPOSITORY
IFS= read -r WORKSPACE
IFS= read -r BUSINESS_MEMORY
IFS= read -r PI_VERSION
IFS= read -r BUILD_CONTEXT
IFS= read -r CONTAINER
IFS= read -r WORKSPACE_VOLUME
IFS= read -r MEMORY_VOLUME

[[ "$PROFILE" =~ ^[A-Za-z0-9-]+$ ]] || { echo 'Error: perfil no válido.' >&2; exit 1; }
[[ "$STACK" = backend || "$STACK" = frontend ]] || { echo 'Error: stack no válido.' >&2; exit 1; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Error: repositorio no válido para Podman.' >&2; exit 1; }
[[ "$WORKSPACE" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || { echo 'Error: workspace no válido.' >&2; exit 1; }
[[ "$BUSINESS_MEMORY" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.md$ ]] || { echo 'Error: memoria de negocio no válida.' >&2; exit 1; }
[[ "$BUILD_CONTEXT" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || { echo 'Error: contexto de imagen no válido.' >&2; exit 1; }
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Error: contenedor no válido.' >&2; exit 1; }
for volume in "$WORKSPACE_VOLUME" "$MEMORY_VOLUME"; do
  [[ "$volume" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Error: volumen no válido.' >&2; exit 1; }
done
[[ "$PI_VERSION" = latest || "$PI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo 'Error: versión Pi no válida.' >&2
  exit 1
}

command -v podman >/dev/null 2>&1 || { echo 'REQUISITO_SISTEMA_FALTANTE: podman' >&2; exit 20; }
[ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] || {
  echo 'Error: Podman debe ejecutarse en modo rootless.' >&2
  exit 1
}
command -v loginctl >/dev/null 2>&1 || { echo 'REQUISITO_SISTEMA_FALTANTE: loginctl' >&2; exit 20; }

image_profile="$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')"
image_repository="$(printf '%s' "$REPOSITORY" | tr '[:upper:]' '[:lower:]')"
image="localhost/prueba-agentes-${image_profile}-${image_repository}:pi"

VERIFICAR() {
  local errores=0
  podman container exists "$CONTAINER" || { echo "❌ Falta contenedor: $CONTAINER"; return 1; }
  podman inspect "$CONTAINER" | jq -e \
    --arg profile "$PROFILE" --arg repository "$REPOSITORY" \
    --arg workspace_volume "$WORKSPACE_VOLUME" --arg memory_volume "$MEMORY_VOLUME" '
      .[0]
      | .State.Running == true
      and .HostConfig.Privileged == false
      and .HostConfig.ReadonlyRootfs == true
      and (.Config.User == "1000:1000" or .Config.User == "1000")
      and (.Config.Labels["prueba-agentes.profile"] == $profile)
      and (.Config.Labels["prueba-agentes.repository"] == $repository)
      and (.HostConfig.CapAdd | type == "array" and length == 0)
      and (.HostConfig.CapDrop | type == "array" and length > 0)
      and .HostConfig.RestartPolicy.Name == "unless-stopped"
      and ([.Mounts[] | select(.Destination == "/workspace" and .Name == $workspace_volume and .Type == "volume")] | length) == 1
      and ([.Mounts[] | select(.Destination == "/opt/memoria-negocio" and .Name == $memory_volume and .Type == "volume" and .RW == false)] | length) == 1
    ' >/dev/null || { echo '❌ El contenedor no cumple su contrato de aislamiento.'; errores=1; }
  podman exec "$CONTAINER" sh -c '
    test -d /workspace/repositorio/.git
    test -s /opt/agente/actual/SKILL.md
    test -s /opt/memoria-negocio/memoria.md
    test -r /opt/memoria-negocio/memoria.md
    test ! -e /run/podman/podman.sock
    test ! -e /var/run/docker.sock
    mkdir -p /workspace/ejecuciones
    test "$(awk "/^CapEff:/ {print \$2}" /proc/1/status)" = 0000000000000000
    test "$(awk "/^NoNewPrivs:/ {print \$2}" /proc/1/status)" = 1
  ' || { echo '❌ Faltan repositorio, agente o memoria dentro del contenedor.'; errores=1; }
  podman exec "$CONTAINER" sh -c '
    test "$PI_HARNESS_CONTAINER_ENFORCED" = 1
    test -f /run/.containerenv
  ' || { echo '❌ Falta la atestación del aislamiento Podman.'; errores=1; }
  podman exec "$CONTAINER" /opt/pi-harness/bin/pi-harness doctor \
    --role "$STACK" --workspace /workspace/repositorio --agent-dir /opt/agente/actual --json \
    | jq -e '.ready == true and .backend == "container" and .sandbox_command == "/run/.containerenv"' >/dev/null || errores=1
  [ "$errores" -eq 0 ] || return 1
  echo "✅ Contenedor '$CONTAINER' verificado: agente, repositorio y memoria disponibles."
}

if [ "$MODO" = verificar ]; then
  [ "$(loginctl show-user "$(id -un)" -p Linger --value)" = yes ] || {
    echo '❌ El usuario rootless no conserva servicios después de cerrar SSH.' >&2
    exit 1
  }
  VERIFICAR
  exit
fi

for required in \
  "$BUILD_CONTEXT/plataforma/Containerfile.modulo" \
  "$BUILD_CONTEXT/plataforma/remoto/ejecutar_tarea.sh" \
  "$BUILD_CONTEXT/pi-harness/bin/pi-harness" \
  "$BUILD_CONTEXT/skills/dev-back/SKILL.md" \
  "$BUILD_CONTEXT/skills/dev-front/SKILL.md"; do
  [ -s "$required" ] || { echo "Error: falta recurso del contenedor: $required" >&2; exit 1; }
done
[ -d "$WORKSPACE/.git" ] || { echo "Error: el repositorio no fue preparado en '$WORKSPACE'." >&2; exit 1; }
[ -s "$BUSINESS_MEMORY" ] || { echo "Error: la memoria de negocio no existe en '$BUSINESS_MEMORY'." >&2; exit 1; }

echo "📦 Construyendo imagen Podman '$image'..."
loginctl enable-linger "$(id -un)"
podman build --build-arg "PI_VERSION=$PI_VERSION" --target "$STACK" -t "$image" \
  -f "$BUILD_CONTEXT/plataforma/Containerfile.modulo" "$BUILD_CONTEXT"

if podman volume exists "$WORKSPACE_VOLUME"; then
  [ "$(podman volume inspect --format '{{index .Labels "prueba-agentes.repository"}}' "$WORKSPACE_VOLUME")" = "$REPOSITORY" ] || {
    echo 'Error: el volumen de código pertenece a otro repositorio.' >&2
    exit 1
  }
else
  podman volume create --label "prueba-agentes.repository=$REPOSITORY" "$WORKSPACE_VOLUME" >/dev/null
fi
if ! podman run --rm --network none --user 0:0 --volume "$WORKSPACE_VOLUME:/workspace" "$image" \
  sh -c 'test -d /workspace/repositorio/.git'; then
  echo "📥 Copiando el repositorio al volumen persistente..."
  tar -C "$WORKSPACE" -cf - . | podman run --rm -i --network none --user 0:0 \
    --volume "$WORKSPACE_VOLUME:/workspace" "$image" sh -c '
      set -eu
      mkdir -p /workspace/repositorio
      tar -xf - -C /workspace/repositorio
      chown -R 1000:1000 /workspace
    '
fi

if podman volume exists "$MEMORY_VOLUME"; then
  [ "$(podman volume inspect --format '{{index .Labels "prueba-agentes.repository"}}' "$MEMORY_VOLUME")" = "$REPOSITORY" ] || {
    echo 'Error: el volumen de memoria pertenece a otro repositorio.' >&2
    exit 1
  }
else
  podman volume create --label "prueba-agentes.repository=$REPOSITORY" "$MEMORY_VOLUME" >/dev/null
fi
# La copia se renueva en cada provisionamiento. Durante la ejecución el volumen
# se monta read-only, por lo que el agente no puede alterar la fuente privada.
podman run --rm -i --network none --user 0:0 --volume "$MEMORY_VOLUME:/memory" "$image" sh -c '
  set -eu
  cat > /memory/memoria.md
  chown 1000:1000 /memory/memoria.md
  chmod 0400 /memory/memoria.md
' < "$BUSINESS_MEMORY"

if podman container exists "$CONTAINER"; then
  [ "$(podman inspect --format '{{index .Config.Labels "prueba-agentes.repository"}}' "$CONTAINER")" = "$REPOSITORY" ] || {
    echo 'Error: el nombre del contenedor está ocupado por otro repositorio.' >&2
    exit 1
  }
  podman rm -f "$CONTAINER" >/dev/null
fi

podman run -d --name "$CONTAINER" \
  --label "prueba-agentes.profile=$PROFILE" --label "prueba-agentes.repository=$REPOSITORY" \
  --user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --pids-limit 512 --memory 2g --cpus 2 --restart unless-stopped \
  --tmpfs /tmp:rw,nosuid,size=512m --volume "$WORKSPACE_VOLUME:/workspace" \
  --volume "$MEMORY_VOLUME:/opt/memoria-negocio:ro" \
  --env BUSINESS_MEMORY_FILE=/opt/memoria-negocio/memoria.md \
  --env PI_HARNESS_CONTAINER_ENFORCED=1 \
  --env REPOSITORY_BASE_REF=HEAD "$image" >/dev/null

# La política de reinicio de Podman se restaura tras reiniciar la VM mediante
# el servicio del usuario rootless. En distribuciones sin esa unidad, el
# contenedor continúa siendo persistente mientras la VM permanezca encendida.
systemctl --user enable podman-restart.service >/dev/null 2>&1 || true

VERIFICAR
