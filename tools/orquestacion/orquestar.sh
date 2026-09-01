#!/usr/bin/env bash
# Entrada única: recolecta memoria, analiza y despacha por VM/repositorio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$ROOT/tools"
DIAGNOSTICO_VMS="${PRUEBA_AGENTES_DIAGNOSTICO_VMS:-$TOOLS_DIR/probar_vms.sh}"
DESPACHADOR="${PRUEBA_AGENTES_DESPACHADOR:-$TOOLS_DIR/validar_y_despachar.sh}"
MODO="ejecutar"
case "${1:-}" in
  --clasificar) MODO="clasificar"; shift ;;
  --descomponer) MODO="descomponer"; shift ;;
esac
TAREA="${1:-}"
[ -n "$TAREA" ] || { echo "Uso: ./tools/orquestar.sh [--clasificar|--descomponer] \"Tarea\"" >&2; exit 1; }
if [ "$MODO" = "clasificar" ]; then "$TOOLS_DIR/clasificar_tarea.sh" "$TAREA"; exit 0; fi

analysis_tmp="$(mktemp -d "${TMPDIR:-/tmp}/orquestacion-contexto.XXXXXX")"
trap 'rm -rf "$analysis_tmp"' EXIT INT TERM
"$TOOLS_DIR/recolectar_contexto_memoria.sh" "$TAREA" > "$analysis_tmp/contexto.json"
REQUISITOS_JSON="$($TOOLS_DIR/analizar_requisitos.sh "$TAREA" "$analysis_tmp/contexto.json")"
if [ "$MODO" = "descomponer" ]; then printf '%s\n' "$REQUISITOS_JSON"; exit 0; fi

mapa_categorias="$(jq -r '.dispatch_categories[]' <<< "$REQUISITOS_JSON")"
[ -n "$mapa_categorias" ] || { echo "CLASIFICACION_AMBIGUA: no se pudo asignar ningún requisito." >&2; exit 2; }
if printf '%s\n' "$mapa_categorias" | grep -Eq '^(qa|security)$'; then
  echo "Hay requisitos QA/seguridad, pero esos roles aún no tienen VM automatizada." >&2; exit 3
fi
if printf '%s\n' "$mapa_categorias" | grep -Ev '^(backend|frontend)$' | grep -q .; then
  echo "Error: categoría no soportada." >&2; exit 1
fi

echo "🔎 Requisitos analizados con contexto de memoria:"
jq -r '.requirements[] | if .target_profile then "  - [\(.id)] \(.category) → \(.target_profile)/\(.repository) [\(.module)]: \(.text)" else "  - [\(.id)] \(.category): \(.text)" end' <<< "$REQUISITOS_JSON"
profiles=()
while IFS= read -r profile; do [ -z "$profile" ] || profiles+=("$profile"); done < <(jq -r '.targets[].profile' <<< "$REQUISITOS_JSON" | sort -u)
[ "${#profiles[@]}" -gt 0 ] || { echo "Error: el analista no produjo destinos." >&2; exit 2; }
"$DIAGNOSTICO_VMS" "${profiles[@]}"

PROJECT_DIR="$($TOOLS_DIR/preparar_proyecto.sh --unico "$TAREA")"
printf '%s\n' "$REQUISITOS_JSON" > "$PROJECT_DIR/REQUISITOS.json"
jq '{version,prompt,private_technology,shared_contracts:{status:.shared_contracts.status,groups:(.shared_contracts.results|length)},inventory:[.inventory[]|{profile,stack,repository,module,kind}]}' \
  "$analysis_tmp/contexto.json" > "$PROJECT_DIR/CONTEXTO_RECOLECTADO.json"
{
  printf 'ANALISTA=requisitos\n'
  printf 'PERFILES=%s\n' "$(printf '%s\n' "${profiles[@]}" | paste -sd, -)"
  printf 'CONTRATOS_COMPARTIDOS=%s\n' "$(jq -r '.context.shared_contracts_status' <<< "$REQUISITOS_JSON")"
  printf 'MEMORIA_TECNOLOGICA=%s\n' "$(jq -r '.context.private_technology_status' <<< "$REQUISITOS_JSON")"
} > "$PROJECT_DIR/CLASIFICACION.txt"
{
  echo "# Requisitos analizados y enrutados"; echo ""; echo "Solicitud original: $TAREA"; echo ""
  jq -r '.requirements[] | "- [\(.id)] **\(.category)**" + (if .target_profile then " → `\(.target_profile)/\(.repository)` (`\(.module)`)" else "" end) + ": \(.text)"' <<< "$REQUISITOS_JSON"
} > "$PROJECT_DIR/REQUISITOS.md"

groups_file="$analysis_tmp/groups.ndjson"
jq -c '([.requirements[] | select(.category == "general") | {id,text,depends_on}]) as $general | [.requirements[] | select(.target_profile != null)] | sort_by(.category,.target_profile,.repository) | group_by([.category,.target_profile,.repository])[] | {category:.[0].category,profile:.[0].target_profile,repository:.[0].repository,module:.[0].module,repository_kind:.[0].repository_kind,workspace:.[0].workspace,technology_constraints:.[0].technology_constraints,requirements:(map({id,text,depends_on}) + $general)}' \
  <<< "$REQUISITOS_JSON" > "$groups_file"
group_count="$(wc -l < "$groups_file" | tr -d ' ')"
multi_category=0
[ "$(jq '.dispatch_categories | length' <<< "$REQUISITOS_JSON")" -le 1 ] || multi_category=1
pids=(); dispatch_ids=(); index=0

while IFS= read -r group; do
  index=$((index + 1))
  category="$(jq -r '.category' <<< "$group")"; profile="$(jq -r '.profile' <<< "$group")"
  repository="$(jq -r '.repository' <<< "$group")"; module="$(jq -r '.module' <<< "$group")"
  dispatch_id="$(printf '%03d-%s-%s-%s' "$index" "$category" "$profile" "$repository" | tr -c 'A-Za-z0-9._-' '-')"
  task_payload="$(jq -r --arg category "$category" --arg profile "$profile" --arg repository "$repository" --arg module "$module" '
    "Solicitud categorizada para " + ($category|ascii_upcase) + ".\n" +
    "Destino decidido por el analista:\n- Perfil VM: " + $profile + "\n- Repositorio: " + $repository + "\n- Módulo: " + $module + "\n" +
    (if .technology_constraints then "- Restricciones tecnológicas relevantes: " + (.technology_constraints|tojson) + "\n" else "" end) +
    "La memoria de negocio privada del repositorio será incorporada localmente por pi-harness.\nEjecuta exclusivamente estos requisitos:\n" +
    ([.requirements[] | "- [" + .id + "] " + .text] | join("\n")) + "\nNo modifiques otros repositorios ni requisitos asignados a otros destinos."
  ' <<< "$group")"
  args=("$category" "$PROJECT_DIR" "$task_payload" --profile "$profile" --repository "$repository" --dispatch-id "$dispatch_id")
  [ "$multi_category" -eq 0 ] || args+=(--fullstack-confirmado)
  "$DESPACHADOR" "${args[@]}" &
  pids+=("$!"); dispatch_ids+=("$dispatch_id")
done < "$groups_file"

failed=0
for position in "${!pids[@]}"; do
  if ! wait "${pids[$position]}"; then echo "❌ Falló el despacho ${dispatch_ids[$position]}." >&2; failed=1; fi
done
"$TOOLS_DIR/generar_reporte.sh" "$PROJECT_DIR" "$TAREA"
[ "$failed" -eq 0 ] || { echo "Revisa las bitácoras en: $PROJECT_DIR" >&2; exit 1; }
echo "✅ Ejecución distribuida terminada"
echo "Destinos ejecutados: $group_count"
echo "Proyecto: $PROJECT_DIR"
echo "Reporte: $PROJECT_DIR/REPORTE_PI.md"
echo "Evidencia: $PROJECT_DIR/EVIDENCIA_AGENTES.md"
