#!/usr/bin/env bash
# Comando forzado de SSH. El usuario web nunca obtiene una consola del host.
set -euo pipefail
umask 077
registry="${1:-/etc/prueba-agentes/destinos-podman.json}"
state="${2:-$HOME/.local/state/orquestador-plataforma}"
[ "${SSH_ORIGINAL_COMMAND:-}" = 'orquestador-v1' ] || { echo 'Error: comando remoto no permitido.' >&2; exit 1; }
[ -f "$registry" ] && [ ! -L "$registry" ] || exit 1
owner="$(stat -c %u "$registry")"; mode="$(stat -c %a "$registry")"
{ [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ]; } && (( (8#$mode & 0022) == 0 )) || {
  echo 'Error: el registro remoto debe estar bajo control administrativo.' >&2; exit 1;
}
payload="$(head -c 32769)"
[ "${#payload}" -le 32768 ] || exit 1
# Se valida el conjunto completo: no se admiten argumentos, rutas ni comandos adicionales.
jq -e '
  def uuid: type=="string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$");
  type=="object" and .version==1 and (.job_id|uuid) and (.target_id|uuid) and (.actor_id|uuid)
  and (.read_only|type=="boolean") and (.prompt|type=="string" and length>0 and length<=30000)
  and ((keys|sort)==(["version","job_id","target_id","actor_id","prompt","container","repository","role","read_only"]|sort))
' <<< "$payload" >/dev/null
target="$(jq -r .target_id <<< "$payload")"; job="$(jq -r .job_id <<< "$payload")"
entry="$(jq -ce --arg id "$target" '.[$id] | select(.enabled==true)' "$registry")"
jq -e --argjson entry "$entry" '.container==$entry.container and .repository==$entry.repository and .role==$entry.role' <<< "$payload" >/dev/null
container="$(jq -r .container <<< "$entry")"
role="$(jq -r .role <<< "$entry")"
volume="$(jq -r .workspace_volume <<< "$entry")"
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] && [[ "$volume" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || exit 1
[[ "$role" = backend || "$role" = frontend ]] || exit 1
# Mínimo obligatorio; la verificación completa del aislamiento sigue siendo un paso del piloto.
podman inspect "$container" | jq -e --arg volume "$volume" '
  .[0] | .State.Running==true and .HostConfig.Privileged==false and .HostConfig.ReadonlyRootfs==true
  and (.Config.User=="1000:1000" or .Config.User=="1000")
  and (.HostConfig.NetworkMode!="host") and (.HostConfig.PidMode!="host")
  and ((.HostConfig.CapDrop // [] | map(ascii_upcase) | index("ALL"))!=null)
  and ([.Mounts[]? | select(.Destination=="/workspace" and .Name==$volume)]|length)==1
  and ([.Mounts[]? | select(.Destination!="/workspace")]|length)==0
' >/dev/null || { echo 'Error: el contenedor no cumple el aislamiento mínimo.' >&2; exit 1; }
# La presencia del binario no demuestra que el host permita sus namespaces.
# Comprobarlo antes de registrar o ejecutar cualquier tarea.
podman exec --user 1000:1000 "$container" bwrap --unshare-all --die-with-parent \
  --ro-bind / / --proc /proc --dev /dev /bin/true >/dev/null 2>&1 || {
  echo 'Error: Bubblewrap no puede aplicar el aislamiento dentro de Podman.' >&2; exit 1;
}
mkdir -p "$state/jobs" "$state/locks"
chmod 700 "$state" "$state/jobs" "$state/locks"
exec 9>"$state/locks/$target"
flock -n 9 || { echo 'Error: módulo ocupado.' >&2; exit 1; }
mkdir "$state/jobs/$job" || { echo 'Error: ejecución ya registrada; requiere consulta administrativa.' >&2; exit 1; }
run="$state/jobs/$job"
jq 'del(.prompt)' <<< "$payload" > "$run/solicitud.json"
printf 'running\n' > "$run/status"
read_only="$(jq -r .read_only <<< "$payload")"
code=0
# El límite se impone dentro del contenedor, por lo que sigue vigente si se corta SSH.
jq -r .prompt <<< "$payload" | podman exec -i --user 1000:1000 --workdir /workspace \
  --env PI_MEMORY_ENABLED=0 "$container" timeout --kill-after=15s 15m \
  /opt/orquestador/ejecutar_tarea.sh "$job" "$role" "$read_only" > "$run/result.txt" 2> "$run/error.log" || code=$?
if [ "$code" -eq 0 ]; then
  printf 'succeeded\n' > "$run/status"
  cat "$run/result.txt"
else
  printf 'failed\n' > "$run/status"
  echo 'Error: el agente no completó la ejecución. Consulta la evidencia administrativa.'
  exit "$code"
fi
