#!/usr/bin/env bash
# Analista: categoriza y asigna cada requisito a perfil, módulo y repositorio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMPT="${1:-}"
CONTEXT_FILE="${2:-}"
[ -n "$PROMPT" ] || { echo "Uso: ./tools/orquestacion/analizar_requisitos.sh \"prompt\" [contexto.json]" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/analista-requisitos.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
if [ -n "$CONTEXT_FILE" ]; then
  [ -s "$CONTEXT_FILE" ] || { echo "Error: contexto inexistente: $CONTEXT_FILE" >&2; exit 1; }
  cp "$CONTEXT_FILE" "$tmp/context.json"
else
  "$ROOT/tools/orquestacion/recolectar_contexto_memoria.sh" "$PROMPT" > "$tmp/context.json"
fi
"$ROOT/tools/orquestacion/descomponer_requisitos.sh" "$PROMPT" > "$tmp/base.json"

prompt_lower="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
read_only=false
if printf '%s\n' "$prompt_lower" | grep -Eq 'solo lectura|sólo lectura|sin modificar|no (modifiques|modificar|edites|editar|escribas|escribir)|read[- ]only'; then
  read_only=true
fi

# Destinos mencionados explícitamente en cualquier requisito de cada dominio.
# Sirven para propagar instrucciones compartidas como "comprueba relaciones"
# sin elegir una VM por la longitud accidental de un alias del prompt completo.
jq -n --slurpfile base "$tmp/base.json" --slurpfile context "$tmp/context.json" '
  [$context[0].inventory[] as $candidate
   | (([ $candidate.aliases[]?, $candidate.repository, $candidate.module ]
       | map(ascii_downcase) | unique
       | map(select(. as $signal | ["api","backend","frontend","laravel","php","vue","interfaz","panel","componente","pantalla"] | index($signal) | not)))) as $signals
   | select([ $base[0].requirements[]
       | select(.category == $candidate.stack)
       | (.text | ascii_downcase) as $text
       | $signals[] as $signal
       | select(($signal | length) > 0 and ($text | contains($signal)))
     ] | length > 0)
   | $candidate]
' > "$tmp/explicit_targets.json"

: > "$tmp/enriched.ndjson"
while IFS= read -r requirement; do
  category="$(jq -r '.category' <<< "$requirement")"
  if [ "$category" = "general" ]; then
    jq -c '. + {target_profile:null,repository:null,module:null,repository_kind:null,workspace:null,technology_constraints:null,depends_on:[]}' <<< "$requirement" >> "$tmp/enriched.ndjson"
    continue
  fi

  has_candidates="$(jq -r --arg stack "$category" '[.inventory[] | select(.stack == $stack)] | length' "$tmp/context.json")"
  if [ "$has_candidates" -eq 0 ]; then
    echo "⚠️ Omitiendo sub-requisito para el rol '$category': no hay VM habilitada en vms.json para este rol." >&2
    jq -c '. + {target_profile:null,repository:null,module:null,repository_kind:null,workspace:null,technology_constraints:null,depends_on:[]}' <<< "$requirement" >> "$tmp/enriched.ndjson"
    continue
  fi

  text_lower="$(jq -r '.text | ascii_downcase | gsub("[áàäâ]"; "a") | gsub("[éèëê]"; "e") | gsub("[íìïî]"; "i") | gsub("[óòöô]"; "o") | gsub("[úùüû]"; "u")' <<< "$requirement")"
  jq -c --arg stack "$category" --arg text "$text_lower" '
    (.shared_contracts.results | tostring | ascii_downcase | gsub("[áàäâ]"; "a") | gsub("[éèëê]"; "e") | gsub("[íìïî]"; "i") | gsub("[óòöô]"; "o") | gsub("[úùüû]"; "u")) as $contracts
    | [.inventory[] | select(.stack == $stack)
      | . as $candidate
      | (([.aliases[]?, .repository, .module]
          | map(ascii_downcase | gsub("[áàäâ]"; "a") | gsub("[éèëê]"; "e") | gsub("[íìïî]"; "i") | gsub("[óòöô]"; "o") | gsub("[úùüû]"; "u")) | unique
          | map(select(. as $signal | ["api","backend","frontend","laravel","php","vue","interfaz","panel","componente","pantalla"] | index($signal) | not)))) as $signals
      | ([$signals[] as $signal | select(($signal | length) > 0 and ($text | contains($signal))) | ($signal | length)] | add // 0) as $requirement_score
      | (if (($contracts | contains(($candidate.repository | ascii_downcase))) or ($contracts | contains(($candidate.module | ascii_downcase)))) then 1 else 0 end) as $contract_score
      | . + {
          explicit_requirement_score:$requirement_score,
          semantic_contract_score:$contract_score,
          match_score:(($requirement_score * 100) + $contract_score)
        }]
  ' "$tmp/context.json" > "$tmp/candidates.json"
  total="$(jq 'length' "$tmp/candidates.json")"
  [ "$total" -gt 0 ] || { echo "ROUTING_SIN_DESTINO: no hay repositorios habilitados para '$category'." >&2; exit 4; }
  explicit_count="$(jq '[.[] | select(.explicit_requirement_score > 0)] | length' "$tmp/candidates.json")"
  if [ "$explicit_count" -gt 0 ]; then
    jq -c '.[] | select(.explicit_requirement_score > 0)' "$tmp/candidates.json" > "$tmp/selected.ndjson"
  elif [ "$total" -eq 1 ]; then
    jq -c '.[0]' "$tmp/candidates.json" > "$tmp/selected.ndjson"
  else
    jq -c --arg stack "$category" '.[] | select(.stack == $stack)' "$tmp/explicit_targets.json" > "$tmp/selected.ndjson"
    inherited_count="$(wc -l < "$tmp/selected.ndjson" | tr -d ' ')"
    if [ "$inherited_count" -eq 0 ]; then
      options="$(jq -r '.[] | "\(.profile):\(.repository)[\(.module)]"' "$tmp/candidates.json" | paste -sd, -)"
      id="$(jq -r '.id' <<< "$requirement")"
      echo "ROUTING_AMBIGUO: $id no identifica un módulo único entre: $options" >&2
      echo "Menciona el módulo o agrega un alias en vms.json." >&2
      exit 5
    fi
  fi
  technology_semantic="$(jq -c '.private_technology.semantic_results // []' "$tmp/context.json")"
  while IFS= read -r selected; do
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
  done < "$tmp/selected.ndjson"
done < <(jq -c '.requirements[]' "$tmp/base.json")

jq -s --arg original "$PROMPT" --argjson read_only "$read_only" --slurpfile context "$tmp/context.json" '
  (to_entries | map(.value + {id:("REQ-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))})) as $requirements
  | $requirements
  | {
    version:2,
    analyst:"requisitos",
    original:$original,
    execution_policy:{read_only:$read_only,allow_workspace_write:($read_only|not),allow_memory_write:($read_only|not)},
    context:{
      private_technology_status:$context[0].private_technology.status,
      shared_contracts_status:$context[0].shared_contracts.status,
      shared_contract_groups:($context[0].shared_contracts.results | length),
      shared_contracts:$context[0].shared_contracts.results
    },
    requirements:$requirements,
    categories:([$requirements[].category] | unique),
    dispatch_categories:([$requirements[].category | select(. != "general")] | unique),
    targets:([$requirements[] | select(.target_profile != null) | {profile:.target_profile,repository,module,category}] | unique)
  }
' "$tmp/enriched.ndjson"
