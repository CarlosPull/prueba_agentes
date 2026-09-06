#!/usr/bin/env bash
# Instalador administrativo Ubuntu/Debian. Entrada JSON por stdin; nunca desde el prompt.
set -euo pipefail
umask 077
[ "$(id -u)" = 0 ] || { echo 'Se requiere la cuenta administrativa de preparación.' >&2; exit 1; }
root=/var/lib/orquestador-installer
exec 8>/var/lib/orquestador-preparacion.lock
flock -n 8 || { echo 'Preparación remota ocupada.' >&2; exit 1; }
# jq puede no estar instalado en una VM recién creada.
command -v apt-get >/dev/null || { echo 'Esta versión prepara VMs Debian/Ubuntu con apt.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >&2
apt-get install -y -qq podman uidmap slirp4netns fuse-overlayfs dbus-user-session git jq openssh-server ca-certificates util-linux >&2
payload="$(head -c 65537)"
[ "${#payload}" -le 65536 ] || exit 1
jq -e '.vm_id|type=="string" and test("^[a-f0-9-]{36}$")' <<< "$payload" >/dev/null
key="$(jq -r .execution_key <<< "$payload" | cut -d' ' -f1-2)"
[[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] || exit 1
if ! id orquestador >/dev/null 2>&1; then useradd --create-home --shell /bin/bash orquestador; fi
service_home="$(getent passwd orquestador | cut -d: -f6)"
[ "$service_home" = /home/orquestador ] || { echo 'Directorio de servicio inesperado.' >&2; exit 1; }
service_uid="$(id -u orquestador)"
[ "$service_uid" -ne 0 ] || exit 1
# useradd debe asignar rangos; no inventar rangos que puedan solaparse.
grep -q '^orquestador:' /etc/subuid && grep -q '^orquestador:' /etc/subgid || { echo 'Configura rangos subordinados exclusivos para orquestador.' >&2; exit 1; }
loginctl enable-linger orquestador
systemctl start "user@$service_uid.service"
run_service() { runuser -u orquestador -- env HOME="$service_home" XDG_RUNTIME_DIR="/run/user/$service_uid" "$@"; }
[ "$(run_service podman info --format '{{.Host.Security.Rootless}}')" = true ] || exit 1
install -d -o root -g root -m 755 /etc/prueba-agentes /opt/orquestador
install -m 755 "$root/plataforma/remoto/ejecutor_podman.sh" /opt/orquestador/ejecutor_podman.sh
install -m 755 "$root/plataforma/remoto/verificar_contenedor.sh" /opt/orquestador/verificar_contenedor.sh
install -d -o root -g root -m 755 /etc/ssh/orquestador-keys
printf 'restrict,command="/opt/orquestador/ejecutor_podman.sh" %s\n' "$key" > /etc/ssh/orquestador-keys/orquestador
chmod 644 /etc/ssh/orquestador-keys/orquestador
# Solo afecta a la cuenta de servicio; su archivo de llaves no es editable por ella.
cat > /etc/ssh/sshd_config.d/00-orquestador.conf <<'SSH'
Match User orquestador
    AuthorizedKeysFile /etc/ssh/orquestador-keys/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand /opt/orquestador/ejecutor_podman.sh
Match all
SSH
/usr/sbin/sshd -t
systemctl reload ssh
registry=/etc/prueba-agentes/destinos-podman.json
[ -e "$registry" ] || printf '{}\n' > "$registry"
chmod 644 "$registry"
if ! jq -e '.target != null' <<< "$payload" >/dev/null; then
  echo ORQUESTADOR_PREPARADO_V1
  exit 0
fi
target="$(jq -c .target <<< "$payload")"
id="$(jq -r .id <<< "$target")"; container="$(jq -r .container <<< "$target")"; role="$(jq -r .stack <<< "$target")"
repository="$(jq -r .repository <<< "$target")"; branch="$(jq -r .git_branch <<< "$target")"; git_url="$(jq -r .git_url <<< "$target")"
[[ "$id" =~ ^[a-f0-9-]{36}$ && "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$repository" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || exit 1
[[ "$role" = frontend || "$role" = backend ]] || exit 1
[[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ && "$branch" != *..* ]] || exit 1
[[ "$git_url" =~ ^https://[a-zA-Z0-9][a-zA-Z0-9.:-]*/[a-zA-Z0-9._/-]+$ ]] || exit 1
volume="orquestador-$id-codigo"
image="localhost/orquestador-$id:1"
# El usuario de servicio necesita leer solo el código del instalador, nunca payload/credenciales.
install -d -m 755 /opt/orquestador/build
cp -R "$root/pi-harness" "$root/skills" "$root/plataforma" /opt/orquestador/build/
chmod -R a+rX /opt/orquestador/build
run_service podman build --target "$role" -t "$image" -f /opt/orquestador/build/plataforma/Containerfile.modulo /opt/orquestador/build >&2
# No tocar un contenedor ajeno ni sustituir un módulo ya ejecutado.
if run_service podman container exists "$container"; then
  existing="$(run_service podman inspect --format '{{index .Config.Labels "orquestador.target"}}' "$container")"
  [ "$existing" = "$id" ] || { echo 'Nombre de contenedor ocupado por otro recurso.' >&2; exit 1; }
  # Un reintento conserva el contenedor y su volumen; solo vuelve a verificar.
else
  if run_service podman volume exists "$volume"; then
    [ "$(run_service podman volume inspect --format '{{index .Labels "orquestador.target"}}' "$volume")" = "$id" ] || exit 1
  else run_service podman volume create --label "orquestador.target=$id" "$volume" >/dev/null; fi
  run_service podman run --rm --network none --user 0:0 --volume "$volume:/workspace" "$image" sh -c 'chown 1000:1000 /workspace' >&2
  # Clonado sin checkout ni ejecución de código del repositorio. Token solo por stdin.
  jq -c '{url:.target.git_url,branch:.target.git_branch,gitToken:(.credentials.gitToken // "")}' <<< "$payload" | run_service podman run --rm -i --user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges --tmpfs /tmp:rw,nosuid,size=128m --volume "$volume:/workspace" "$image" /opt/orquestador/clonar.sh >&2
  provider="$(jq -r .credentials.provider <<< "$payload")"; model="$(jq -r .credentials.model <<< "$payload")"
  [[ "$provider" = anthropic || "$provider" = openai ]] || exit 1
  [[ "$model" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ ]] || exit 1
  secret="orquestador-$id-api"
  # El secreto es específico de este módulo. No reemplazar uno existente en reintentos.
  if ! run_service podman secret inspect "$secret" >/dev/null 2>&1; then
    jq -jr .credentials.apiKey <<< "$payload" | run_service podman secret create "$secret" - >/dev/null
  fi
  secret_var=ANTHROPIC_API_KEY; [ "$provider" != openai ] || secret_var=OPENAI_API_KEY
  run_service podman run -d --name "$container" --label "orquestador.target=$id" --user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --pids-limit 512 --memory 2g --cpus 2 --tmpfs /tmp:rw,nosuid,size=512m --volume "$volume:/workspace" \
    --secret "$secret,type=env,target=$secret_var" --env "PI_PROVIDER=$provider" --env "PI_MODEL=$model" --env 'REPOSITORY_BASE_REF=HEAD' "$image" >/dev/null
fi
run_service podman start "$container" >/dev/null
run_service /opt/orquestador/verificar_contenedor.sh "$container" "$volume" >&2
run_service podman exec "$container" /opt/pi-harness/bin/pi-harness doctor --role "$role" --workspace /workspace/repositorio --agent-dir /opt/agente/actual --json >&2
# El registro se habilita solo después de todas las comprobaciones; sustitución atómica.
jq --arg id "$id" --arg container "$container" --arg repo "$repository" --arg role "$role" --arg volume "$volume" \
  '.[$id]={container:$container,repository:$repo,role:$role,workspace_volume:$volume,enabled:true}' "$registry" > "$registry.tmp"
chmod 644 "$registry.tmp"
mv "$registry.tmp" "$registry"
echo ORQUESTADOR_PREPARADO_V1
