#!/usr/bin/env bash
# Cliente administrativo mTLS; el operador no se conecta directamente a Cognee.
set -euo pipefail
ACTION="${1:-}"; shift || true
URL="${MEMORY_GATEWAY_URL:-}"; CERT="${MEMORY_GATEWAY_CLIENT_CERT:-}"; KEY="${MEMORY_GATEWAY_CLIENT_KEY:-}"; CA="${MEMORY_GATEWAY_CA:-}"
[ -n "$URL" ] && [ -s "$CERT" ] && [ -s "$KEY" ] && [ -s "$CA" ] || {
  echo "Error: define MEMORY_GATEWAY_URL, MEMORY_GATEWAY_CLIENT_CERT, MEMORY_GATEWAY_CLIENT_KEY y MEMORY_GATEWAY_CA." >&2; exit 1;
}
CALL() { curl --fail-with-body --silent --show-error --cacert "$CA" --cert "$CERT" --key "$KEY" "$@"; }
case "$ACTION" in
  verificar) CALL "$URL/health" | jq . ;;
  guardar-negocio)
    tenant="${1:-}"; content="${2:-}"; [ -n "$tenant" ] && [ -n "$content" ] || exit 1
    CALL -H 'Content-Type: application/json' -X POST "$URL/v1/admin/memories" \
      --data "$(jq -cn --arg tenant "$tenant" --arg content "$content" '{layer:"business",tenant_id:$tenant,content:$content}')" | jq . ;;
  guardar-empresa)
    content="${1:-}"; [ -n "$content" ] || exit 1
    CALL -H 'Content-Type: application/json' -X POST "$URL/v1/admin/memories" \
      --data "$(jq -cn --arg content "$content" '{layer:"company",content:$content}')" | jq . ;;
  guardar-tecnologias)
    repository="${1:-}"; technology_json="${2:-}"; [ -n "$repository" ] && [ -n "$technology_json" ] || exit 1
    jq -e '.technologies | type == "array"' <<< "$technology_json" >/dev/null || { echo "Error: inventario tecnológico inválido." >&2; exit 1; }
    CALL -H 'Content-Type: application/json' -X POST "$URL/v1/admin/memories" \
      --data "$(jq -cn --arg repository "$repository" --argjson technology "$technology_json" '{layer:"company",memory_kind:"repository_technology",repository:$repository,technologies:($technology.technologies // []),architecture:($technology.architecture // "")}')" | jq . ;;
  *) echo "Uso: memoria_gateway.sh verificar|guardar-negocio <tenant> <texto>|guardar-empresa <texto>|guardar-tecnologias <repositorio> <json>" >&2; exit 1 ;;
esac
