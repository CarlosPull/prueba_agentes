#!/usr/bin/env bash
# Reúne inventario privado de tecnologías y contratos compartidos antes del análisis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PRIVATE_MEMORY="${PRUEBA_AGENTES_PRIVATE_TECH_MEMORY:-$ROOT/.private/tecnologias.json}"
PROMPT="${1:-}"
[ -n "$PROMPT" ] || { echo "Uso: ./tools/orquestacion/recolectar_contexto_memoria.sh \"prompt\"" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/recolector-memoria.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

private_status="missing"
private_json='{"version":1,"repositories":{}}'
if [ -s "$PRIVATE_MEMORY" ]; then
  jq -e '.version == 1 and (.repositories | type == "object")' "$PRIVATE_MEMORY" >/dev/null || {
    echo "Error: memoria tecnológica privada inválida: $PRIVATE_MEMORY" >&2; exit 1;
  }
  private_status="loaded"
  private_json="$(cat "$PRIVATE_MEMORY")"
elif [ "${PRUEBA_AGENTES_PRIVATE_MEMORY_REQUIRED:-0}" = "1" ]; then
  echo "Error: falta la memoria tecnológica privada obligatoria: $PRIVATE_MEMORY" >&2
  exit 1
fi

inventory="$(jq -c --argjson private "$private_json" '
  [to_entries[] as $vm
   | select($vm.value.engine == "pi" and $vm.value.dispatch_enabled == true)
   | ($vm.value.repositories // [{id:$vm.key,module:$vm.value.stack,kind:$vm.value.stack,path:$vm.value.workspace,business_memory:"",aliases:[$vm.key,$vm.value.stack]}])[]
   | {
       profile:$vm.key, stack:$vm.value.stack, ip:$vm.value.ip, user:$vm.value.user,
       repository:.id, module:.module, kind:.kind, workspace:.path,
       business_memory:(.business_memory // ""), aliases:(.aliases // []),
       technology:($private.repositories[.id] // null)
     }]
' "$VMS_CONF")"

gateway_status="disabled"
contracts='[]'
technology_semantic='[]'
enabled_memory_count="$(jq '[to_entries[] | select(.value.engine == "pi" and .value.dispatch_enabled == true and (.value.memory.enabled // false))] | length' "$VMS_CONF")"
if [ "$enabled_memory_count" -gt 0 ]; then
  gateway_status="unavailable"
  gateway_url="${MEMORY_GATEWAY_URL:-$(jq -r '[to_entries[] | select(.value.engine == "pi" and .value.dispatch_enabled == true and (.value.memory.enabled // false)) | .value.memory.gateway_url] | unique | if length == 1 then .[0] else "" end' "$VMS_CONF")}"
  collector_cert="${MEMORY_GATEWAY_COLLECTOR_CERT:-$ROOT/.private/memory-gateway-pki/clients/orchestrator-analyst.crt}"
  collector_key="${MEMORY_GATEWAY_COLLECTOR_KEY:-$ROOT/.private/memory-gateway-pki/clients/orchestrator-analyst.key}"
  collector_ca="${MEMORY_GATEWAY_CA:-$ROOT/.private/memory-gateway-pki/ca.crt}"
  if [ -n "$gateway_url" ] && [ -s "$collector_cert" ] && [ -s "$collector_key" ] && [ -s "$collector_ca" ]; then
    if ! curl --fail-with-body --silent --connect-timeout 2 --cacert "$collector_ca" --cert "$collector_cert" --key "$collector_key" "$gateway_url/health" >/dev/null 2>&1; then
      if curl --fail-with-body --silent --connect-timeout 2 --cacert "$collector_ca" --cert "$collector_cert" --key "$collector_key" "https://127.0.0.1:9443/health" >/dev/null 2>&1; then
        gateway_url="https://127.0.0.1:9443"
      fi
    fi

    if curl --fail-with-body --silent --connect-timeout 2 --cacert "$collector_ca" --cert "$collector_cert" --key "$collector_key" "$gateway_url/health" >/dev/null 2>&1; then
      tmp_contracts="$tmp_dir/contratos.ndjson"
      while IFS= read -r core_id; do
        [ -n "$core_id" ] || continue
        response="$(curl --fail-with-body --silent --connect-timeout 3 --cacert "$collector_ca" --cert "$collector_cert" --key "$collector_key" \
          -H 'Content-Type: application/json' -X POST "$gateway_url/v1/memory/search" \
          --data "$(jq -cn --arg query "$PROMPT" --arg core "$core_id" '{layer:"shared_contracts",query:$query,core_id:$core}')" 2>/dev/null || true)"
        [ -z "$response" ] || jq -cn --arg core_id "$core_id" --argjson response "$response" '{core_id:$core_id,response:$response}' >> "$tmp_contracts" 2>/dev/null || true
      done < <(jq -r '[to_entries[] | select(.value.engine == "pi" and .value.dispatch_enabled == true and (.value.memory.enabled // false)) | .value.memory.core_id] | unique[]' "$VMS_CONF")
      [ ! -f "$tmp_contracts" ] || contracts="$(jq -s '.' "$tmp_contracts" 2>/dev/null || echo '[]')"

      technology_response="$(curl --fail-with-body --silent --connect-timeout 3 --cacert "$collector_ca" --cert "$collector_cert" --key "$collector_key" \
        -H 'Content-Type: application/json' -X POST "$gateway_url/v1/memory/search" \
        --data "$(jq -cn --arg query "$PROMPT" '{layer:"company",query:("Tecnologías, arquitectura y convenciones relevantes para: " + $query)}')" 2>/dev/null || true)"
      if [ -n "$technology_response" ]; then
        technology_semantic="$(jq -cn --argjson response "$technology_response" '[{source:"memory-gateway",response:$response}]' 2>/dev/null || echo '[]')"
      fi
      if [ "$private_status" = "loaded" ]; then private_status="hybrid"; else private_status="loaded_gateway"; fi
      gateway_status="loaded"
    else
      echo "⚠️ Memory Gateway no disponible en $gateway_url; continuando con el inventario de tecnología local." >&2
      gateway_status="unavailable"
    fi
  else
    echo "⚠️ Credenciales mTLS del Memory Gateway no configuradas localmente; usando inventario local." >&2
    gateway_status="disabled"
  fi
fi


jq -n --arg prompt "$PROMPT" --arg private_status "$private_status" --arg private_source "$PRIVATE_MEMORY" \
  --arg gateway_status "$gateway_status" --argjson inventory "$inventory" --argjson contracts "$contracts" \
  --argjson technology_semantic "$technology_semantic" '
  {
    version:1,
    prompt:$prompt,
    private_technology:{status:$private_status,source:$private_source,semantic_results:$technology_semantic},
    shared_contracts:{status:$gateway_status,results:$contracts},
    inventory:$inventory
  }
'
