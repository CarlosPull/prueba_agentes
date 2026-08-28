#!/usr/bin/env bash
# Punto de entrada único: clasifica un prompt y lo despacha a la VM adecuada.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"
DIAGNOSTICO_VMS="${PRUEBA_AGENTES_DIAGNOSTICO_VMS:-$TOOLS_DIR/probar_vms.sh}"
DESPACHADOR="${PRUEBA_AGENTES_DESPACHADOR:-$TOOLS_DIR/validar_y_despachar.sh}"

MODO="ejecutar"
case "${1:-}" in
  --clasificar)
    MODO="clasificar"
    shift
    ;;
  --descomponer)
    MODO="descomponer"
    shift
    ;;
esac

TAREA="${1:-}"
if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/orquestar.sh [--clasificar|--descomponer] \"Tarea\"" >&2
  exit 1
fi

if [ "$MODO" = "clasificar" ]; then
  "$TOOLS_DIR/clasificar_tarea.sh" "$TAREA"
  exit 0
fi

REQUISITOS_JSON="$($TOOLS_DIR/descomponer_requisitos.sh "$TAREA")"

if [ "$MODO" = "descomponer" ]; then
  printf '%s\n' "$REQUISITOS_JSON"
  exit 0
fi

mapa_categorias="$(printf '%s\n' "$REQUISITOS_JSON" | jq -r '.dispatch_categories[]')"
[ -n "$mapa_categorias" ] || {
  echo "CLASIFICACION_AMBIGUA: no se pudo asignar ningún requisito a un rol." >&2
  exit 2
}

if printf '%s\n' "$mapa_categorias" | grep -Eq '^(qa|security)$'; then
  no_soportadas="$(printf '%s\n' "$mapa_categorias" | grep -E '^(qa|security)$' | paste -sd, -)"
  echo "REQUISITOS CLASIFICADOS COMO '$no_soportadas', pero esos roles todavía no tienen despacho automatizado en tools/." >&2
  echo "No se modificó ninguna VM." >&2
  exit 3
fi

if printf '%s\n' "$mapa_categorias" | grep -Ev '^(backend|frontend)$' | grep -q .; then
  echo "Error: la descomposición produjo una categoría no soportada." >&2
  exit 1
fi

tiene_backend=0
tiene_frontend=0
printf '%s\n' "$mapa_categorias" | grep -qx backend && tiene_backend=1
printf '%s\n' "$mapa_categorias" | grep -qx frontend && tiene_frontend=1

if [ "$tiene_backend" -eq 1 ] && [ "$tiene_frontend" -eq 1 ]; then
  ROL="fullstack"
elif [ "$tiene_backend" -eq 1 ]; then
  ROL="backend"
else
  ROL="frontend"
fi

echo "🔎 Requisitos detectados y categorizados:"
printf '%s\n' "$REQUISITOS_JSON" | jq -r '.requirements[] | "  - [\(.id)] \(.category): \(.text)"'
echo "🧭 Despacho resumido: $ROL"
roles_diagnostico=()
[ "$tiene_backend" -eq 0 ] || roles_diagnostico+=(backend)
[ "$tiene_frontend" -eq 0 ] || roles_diagnostico+=(frontend)
"$DIAGNOSTICO_VMS" "${roles_diagnostico[@]}"

PROJECT_DIR="$($TOOLS_DIR/preparar_proyecto.sh --unico "$TAREA")"
printf '%s\n' "$REQUISITOS_JSON" > "$PROJECT_DIR/REQUISITOS.json"
{
  printf 'ROL_CLASIFICADO=%s\n' "$ROL"
  printf 'CATEGORIAS=%s\n' "$(printf '%s\n' "$mapa_categorias" | paste -sd, -)"
} > "$PROJECT_DIR/CLASIFICACION.txt"

{
  echo "# Requisitos categorizados"
  echo ""
  echo "Solicitud original: $TAREA"
  echo ""
  for categoria in backend frontend qa security general; do
    requisitos_categoria="$(printf '%s\n' "$REQUISITOS_JSON" | jq -r --arg categoria "$categoria" '.requirements[] | select(.category == $categoria) | "- [\(.id)] \(.text)"')"
    [ -n "$requisitos_categoria" ] || continue
    titulo="$(printf '%s' "$categoria" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    echo "## $titulo"
    echo ""
    printf '%s\n' "$requisitos_categoria"
    echo ""
  done
} > "$PROJECT_DIR/REQUISITOS.md"

CONSTRUIR_TAREA_ROL() {
  local rol="$1"
  local etiqueta
  etiqueta="$(printf '%s' "$rol" | tr '[:lower:]' '[:upper:]')"
  {
    printf 'Solicitud categorizada para %s. Ejecuta exclusivamente estos requisitos dentro de tu dominio:\n' "$etiqueta"
    printf '%s\n' "$REQUISITOS_JSON" | jq -r --arg rol "$rol" '
      .requirements[] |
      select(.category == $rol or .category == "general") |
      "- [\(.id)] \(.text)"
    '
    printf 'No ejecutes requisitos asignados a otros roles.\n'
  }
}

pid_backend=""
pid_frontend=""

if [ "$tiene_backend" -eq 1 ]; then
  TAREA_BACKEND="$(CONSTRUIR_TAREA_ROL backend)"
  if [ "$ROL" = "fullstack" ]; then
    "$DESPACHADOR" backend "$PROJECT_DIR" "$TAREA_BACKEND" --fullstack-confirmado &
  else
    "$DESPACHADOR" backend "$PROJECT_DIR" "$TAREA_BACKEND" &
  fi
  pid_backend="$!"
fi

if [ "$tiene_frontend" -eq 1 ]; then
  TAREA_FRONTEND="$(CONSTRUIR_TAREA_ROL frontend)"
  if [ "$ROL" = "fullstack" ]; then
    "$DESPACHADOR" frontend "$PROJECT_DIR" "$TAREA_FRONTEND" --fullstack-confirmado &
  else
    "$DESPACHADOR" frontend "$PROJECT_DIR" "$TAREA_FRONTEND" &
  fi
  pid_frontend="$!"
fi

estado_backend=0
estado_frontend=0
[ -z "$pid_backend" ] || wait "$pid_backend" || estado_backend="$?"
[ -z "$pid_frontend" ] || wait "$pid_frontend" || estado_frontend="$?"

"$TOOLS_DIR/generar_reporte.sh" "$PROJECT_DIR" "$TAREA"

if [ "$estado_backend" -ne 0 ] || [ "$estado_frontend" -ne 0 ]; then
  echo "❌ Uno o más despachos Pi fallaron (backend=$estado_backend, frontend=$estado_frontend)." >&2
  echo "Revisa las bitácoras en: $PROJECT_DIR" >&2
  exit 1
fi

echo "✅ Ejecución terminada"
echo "Rol: $ROL"
echo "Proyecto: $PROJECT_DIR"
echo "Reporte: $PROJECT_DIR/REPORTE_PI.md"
echo "Evidencia: $PROJECT_DIR/EVIDENCIA_AGENTES.md"
