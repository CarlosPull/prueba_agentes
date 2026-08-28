#!/usr/bin/env bash
# Punto de entrada único: clasifica un prompt y lo despacha a la VM adecuada.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"

MODO="ejecutar"
if [ "${1:-}" = "--clasificar" ]; then
  MODO="clasificar"
  shift
fi

TAREA="${1:-}"
if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/orquestar.sh [--clasificar] \"Tarea\"" >&2
  exit 1
fi

ROL="$($TOOLS_DIR/clasificar_tarea.sh "$TAREA")"

if [ "$MODO" = "clasificar" ]; then
  printf '%s\n' "$ROL"
  exit 0
fi

case "$ROL" in
  backend|frontend|fullstack) ;;
  qa|security)
    echo "TAREA CLASIFICADA COMO '$ROL', pero ese rol todavía no tiene despacho automatizado en tools/." >&2
    echo "No se modificó ninguna VM." >&2
    exit 3
    ;;
  *)
    echo "Error: el clasificador devolvió un rol no soportado: '$ROL'." >&2
    exit 1
    ;;
esac

echo "🔎 Rol detectado automáticamente: $ROL"
"$TOOLS_DIR/probar_vms.sh"

PROJECT_DIR="$($TOOLS_DIR/preparar_proyecto.sh --unico "$TAREA")"
printf 'ROL_CLASIFICADO=%s\n' "$ROL" > "$PROJECT_DIR/CLASIFICACION.txt"

if [ "$ROL" = "fullstack" ]; then
  TAREA_BACKEND="Solicitud Full-Stack explícita. Ejecuta exclusivamente la parte de Backend en Laravel/PHP dentro de tu workspace. No realices trabajo de interfaz. Solicitud original: $TAREA"
  TAREA_FRONTEND="Solicitud Full-Stack explícita. Ejecuta exclusivamente la parte de Frontend en Vue/TypeScript dentro de tu workspace. No realices trabajo de servidor. Solicitud original: $TAREA"

  "$TOOLS_DIR/validar_y_despachar.sh" backend "$PROJECT_DIR" "$TAREA_BACKEND" --fullstack-confirmado
  "$TOOLS_DIR/validar_y_despachar.sh" frontend "$PROJECT_DIR" "$TAREA_FRONTEND" --fullstack-confirmado
else
  "$TOOLS_DIR/validar_y_despachar.sh" "$ROL" "$PROJECT_DIR" "$TAREA"
fi

"$TOOLS_DIR/generar_reporte.sh" "$PROJECT_DIR" "$TAREA"

echo "✅ Ejecución terminada"
echo "Rol: $ROL"
echo "Proyecto: $PROJECT_DIR"
echo "Reporte: $PROJECT_DIR/AGENT_RUNNER.md"
echo "Evidencia: $PROJECT_DIR/EVIDENCIA_AGENTES.md"
