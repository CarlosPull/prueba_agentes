#!/usr/bin/env bash
# Habilita el Gateway central en perfiles Pi; no almacena credenciales de Cognee.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
GATEWAY_URL="${1:-}"
CORE_ID="${2:-}"
TENANT_ID="${3:-}"
[ -n "$GATEWAY_URL" ] && [ -n "$CORE_ID" ] && [ -n "$TENANT_ID" ] || {
  echo "Uso: ./tools/configurar_memory_gateway.sh <https-url> <core_id> <tenant_id> [--leer-negocio] [--leer-empresa] [perfil ...]" >&2
  exit 1
}
[[ "$GATEWAY_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "Error: el Gateway debe usar HTTPS." >&2; exit 1; }
[[ "$CORE_ID" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Error: core_id no válido." >&2; exit 1; }
[[ "$TENANT_ID" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Error: tenant_id no válido." >&2; exit 1; }
shift 3

profiles=(); read_business=false; read_company=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --leer-negocio) read_business=true ;;
    --leer-empresa) read_company=true ;;
    --*) echo "Error: opción no reconocida: $1" >&2; exit 1 ;;
    *) profiles+=("$1") ;;
  esac
  shift
done
if [ "${#profiles[@]}" -eq 0 ]; then
  while IFS= read -r profile; do profiles+=("$profile"); done < <(
    jq -r 'to_entries[] | select(.value.engine == "pi" and .value.dispatch_enabled == true) | .key' "$VMS_CONF"
  )
fi
[ "${#profiles[@]}" -gt 0 ] || { echo "Error: no hay perfiles Pi habilitados." >&2; exit 1; }

tmp="$(mktemp "$VMS_CONF.gateway.XXXXXX")"; cp "$VMS_CONF" "$tmp"
for profile in "${profiles[@]}"; do
  user="$(jq -er --arg profile "$profile" 'select(.[$profile].engine == "pi") | .[$profile].user' "$tmp")" || {
    rm -f "$tmp"; echo "Error: '$profile' no es un perfil Pi válido." >&2; exit 1;
  }
  credential_dir="/home/$user/.config/prueba-agentes/memory-gateway"
  next="$(mktemp "$VMS_CONF.gateway-paso.XXXXXX")"
  jq --arg profile "$profile" --arg url "${GATEWAY_URL%/}" --arg core "$CORE_ID" --arg tenant "$TENANT_ID" \
    --arg dir "$credential_dir" --argjson business "$read_business" --argjson company "$read_company" '
    .[$profile].memory = {
      enabled:true, gateway_url:$url, core_id:$core, tenant_id:$tenant,
      read_business:$business, read_company:$company,
      tls_key:($dir + "/client.key"), tls_cert:($dir + "/client.crt"), tls_ca:($dir + "/ca.crt")
    }
  ' "$tmp" > "$next"; mv "$next" "$tmp"
done
chmod --reference="$VMS_CONF" "$tmp" 2>/dev/null || chmod 0644 "$tmp"; mv "$tmp" "$VMS_CONF"
printf '✓ Memory Gateway configurado en:'; printf ' %s' "${profiles[@]}"; printf '\n'
