#!/usr/bin/env bash
# Herramienta 2: Crear el directorio del proyecto y guardar SOLICITUD.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_DIR="$ROOT/proyectos"

TAREA="${1:-}"
if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/preparar_proyecto.sh \"Descripción de la tarea\""
  exit 1
fi

SLUG=$(echo "$TAREA" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-//' -e 's/-$//' | cut -c 1-50)
SLUG="${SLUG:-proyecto}"
PROJECT_DIR="$PROJECTS_DIR/$SLUG"
mkdir -p "$PROJECT_DIR"

echo "# Solicitud original" > "$PROJECT_DIR/SOLICITUD.md"
echo "" >> "$PROJECT_DIR/SOLICITUD.md"
echo "$TAREA" >> "$PROJECT_DIR/SOLICITUD.md"

echo "$PROJECT_DIR"
