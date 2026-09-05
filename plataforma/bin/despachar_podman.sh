#!/usr/bin/env bash
# Adaptador interno de orquestar.sh. No se expone como comando de usuarios.
set -euo pipefail
umask 077
role="${1:?}"; project="${2:?}"; task="${3:?}"
shift 3
profile=''; repository=''; dispatch=''; analyst_read_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --dispatch-id) dispatch="$2"; shift 2 ;;
    --read-only) analyst_read_only=1; shift ;;
    --fullstack-confirmado) shift ;;
    *) echo 'Opción no autorizada.' >&2; exit 1 ;;
  esac
done
: "${PLATFORM_CONNECTION_FILE:?}" "${PLATFORM_JOB_ID:?}" "${PLATFORM_TARGET_ID:?}" "${PLATFORM_USER_ID:?}" "${PLATFORM_READ_ONLY:?}"
[ "$profile" = "$PLATFORM_TARGET_ID" ] || exit 1
jq -e --arg role "$role" --arg repo "$repository" '.stack==$role and .repository==$repo and .isolationVerified==true' "$PLATFORM_CONNECTION_FILE" >/dev/null
host="$(jq -r .host "$PLATFORM_CONNECTION_FILE")"
user="$(jq -r .user "$PLATFORM_CONNECTION_FILE")"
port="$(jq -r .port "$PLATFORM_CONNECTION_FILE")"
key="$(jq -r .identityFile "$PLATFORM_CONNECTION_FILE")"
known="$(jq -r .knownHostsFile "$PLATFORM_CONNECTION_FILE")"
container="$(jq -r .container "$PLATFORM_CONNECTION_FILE")"
[[ "$dispatch" =~ ^[A-Za-z0-9._-]+$ ]] || exit 1
mkdir "$project/.ejecucion_lock.$dispatch" || exit 1
payload="$(jq -cn --arg job "$PLATFORM_JOB_ID" --arg target "$PLATFORM_TARGET_ID" --arg actor "$PLATFORM_USER_ID" \
  --arg prompt "$task" --arg container "$container" --arg repository "$repository" --arg role "$role" \
  --argjson read_only "$({ [ "$PLATFORM_READ_ONLY" = 1 ] || [ "$analyst_read_only" = 1 ]; } && echo true || echo false)" \
  '{version:1,job_id:$job,target_id:$target,actor_id:$actor,prompt:$prompt,container:$container,repository:$repository,role:$role,read_only:$read_only}')"
result="$(dirname "$PLATFORM_CONNECTION_FILE")/resultado.txt"
# La clave debe tener command=ejecutor_podman.sh y restrict en authorized_keys.
ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
  -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no \
  -o "UserKnownHostsFile=$known" -i "$key" -p "$port" "$user@$host" orquestador-v1 \
  <<< "$payload" > "$result"
cp "$result" "$project/${dispatch}_output.log"
printf 'Solicitud: %s\nSolicitante: %s\nDestino: %s\nContenedor: %s\n' \
  "$PLATFORM_JOB_ID" "$PLATFORM_USER_ID" "$PLATFORM_TARGET_ID" "$container" > "$project/EVIDENCIA_${dispatch}.md"
