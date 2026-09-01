#!/usr/bin/env bash
# Analista: categoriza y asigna cada requisito a perfil, módulo y repositorio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMPT="${1:-}"
CONTEXT_FILE="${2:-}"
[ -n "$PROMPT" ] || { echo "Uso: ./tools/analizar_requisitos.sh \"prompt\" [contexto.json]" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/analista-requisitos.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
if [ -n "$CONTEXT_FILE" ]; then
  [ -s "$CONTEXT_FILE" ] || { echo "Error: contexto inexistente: $CONTEXT_FILE" >&2; exit 1; }
  cp "$CONTEXT_FILE" "$tmp/context.json"
else
  "$ROOT/tools/recolectar_contexto_memoria.sh" "$PROMPT" > "$tmp/context.json"
fi
"$ROOT/tools/descomponer_requisitos.sh" "$PROMPT" > "$tmp/base.json"

: > "$tmp/enriched.ndjson"
while IFS= read -r requirement; do
  category="$(jq -r '.category' <<< "$requirement")"
  if [ "$category" = "general" ] || [ "$category" = "qa" ] || [ "$category" = "security" ]; then
    jq -c '. + {target_profile:null,repository:null,module:null,repository_kind:null,workspace:null,technology_constraints:null,depends_on:[]}' <<< "$requirement" >> "$tmp/enriched.ndjson"
    continue
  fi

  text_lower="$(jq -r '.text | ascii_downcase' <<< "$requirement")"
  prompt_lower="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
  jq -c --arg stack "$category" --arg text "$text_lower" --arg original "$prompt_lower" '
    (.shared_contracts.results | tostring | ascii_downcase) as $contracts
    | [.inventory[] | select(.stack == $stack)
      | . as $candidate
      | (([.aliases[]?, .repository, .module] | map(ascii_downcase) | unique)) as $signals
      | ([$signals[] as $signal | select(($signal | length) > 0 and ($text | contains($signal))) | ($signal | length)] | add // 0) as $requirement_score
      | ([$signals[] as $signal | select(($signal | length) > 0 and ($original | contains($signal))) | ($signal | length)] | add // 0) as $original_score
      | (if (($contracts | contains(($candidate.repository | ascii_downcase))) or ($contracts | contains(($candidate.module | ascii_downcase)))) then 1 else 0 end) as $contract_score
      | . + {
          explicit_requirement_score:$requirement_score,
          original_context_score:$original_score,
          semantic_contract_score:$contract_score,
          match_score:(($requirement_score * 100) + ($original_score * 20) + $contract_score)
        }]
  ' "$tmp/context.json" > "$tmp/candidates.json"
  total="$(jq 'length' "$tmp/candidates.json")"
  [ "$total" -gt 0 ] || { echo "ROUTING_SIN_DESTINO: no hay repositorios habilitados para '$category'." >&2; exit 4; }
  max_score="$(jq '[.[].match_score] | max // 0' "$tmp/candidates.json")"
  if [ "$total" -eq 1 ]; then
    selected="$(jq '.[0]' "$tmp/candidates.json")"
  else
    matches="$(jq --argjson score "$max_score" '[.[] | select(.match_score == $score)] | length' "$tmp/candidates.json")"
    if [ "$max_score" -eq 0 ] || [ "$matches" -ne 1 ]; then
      options="$(jq -r '.[] | "\(.profile):\(.repository)[\(.module)]"' "$tmp/candidates.json" | paste -sd, -)"
      id="$(jq -r '.id' <<< "$requirement")"
      echo "ROUTING_AMBIGUO: $id no identifica un módulo único entre: $options" >&2
      echo "Menciona el módulo o agrega un alias en vms.json." >&2
      exit 5
    fi
    selected="$(jq --argjson score "$max_score" '[.[] | select(.match_score == $score)][0]' "$tmp/candidates.json")"
  fi
  technology_semantic="$(jq -c '.private_technology.semantic_results // []' "$tmp/context.json")"
  jq -cn --argjson requirement "$requirement" --argjson selected "$selected" --argjson semantic "$technology_semantic" '
    $requirement + {
      target_profile:$selected.profile,
      repository:$selected.repository,
      module:$selected.module,
      repository_kind:$selected.kind,
      workspace:$selected.workspace,
      technology_constraints:(
        if $selected.technology == null and ($semantic | length) == 0 then null
        elif $selected.technology == null then {semantic_context:$semantic}
        elif ($semantic | length) == 0 then $selected.technology
        else $selected.technology + {semantic_context:$semantic}
        end
      ),
      depends_on:[]
    }
  ' >> "$tmp/enriched.ndjson"
done < <(jq -c '.requirements[]' "$tmp/base.json")

jq -s --arg original "$PROMPT" --slurpfile context "$tmp/context.json" '
  {
    version:2,
    analyst:"requisitos",
    original:$original,
    context:{
      private_technology_status:$context[0].private_technology.status,
      shared_contracts_status:$context[0].shared_contracts.status,
      shared_contract_groups:($context[0].shared_contracts.results | length),
      shared_contracts:$context[0].shared_contracts.results
    },
    requirements:.,
    categories:([.[].category] | unique),
    dispatch_categories:([.[].category | select(. != "general")] | unique),
    targets:([.[] | select(.target_profile != null) | {profile:.target_profile,repository,module,category}] | unique)
  }
' "$tmp/enriched.ndjson"
