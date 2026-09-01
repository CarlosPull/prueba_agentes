#!/usr/bin/env bash
# Una pasada de sincronización para todos los perfiles con source_mode=local.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
estado=0

while IFS= read -r perfil; do
  [ -n "$perfil" ] || continue
  if ! "$ROOT/tools/sincronizar_agente_local.sh" "$perfil" --silencioso; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Error sincronizando '$perfil'." >&2
    estado=1
  fi
done < <(jq -r 'to_entries[] | select(.value.agent_update_mode == "local") | .key' "$VMS_CONF")

exit "$estado"
