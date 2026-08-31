#!/usr/bin/env bash
# Herramienta 2: Crear el directorio del proyecto y guardar SOLICITUD.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_DIR="${PRUEBA_AGENTES_PROJECTS_DIR:-$ROOT/logs}"

UNICO=0
if [ "${1:-}" = "--unico" ]; then
  UNICO=1
  shift
fi

TAREA="${1:-}"
if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/preparar_proyecto.sh [--unico] \"Descripción de la tarea\""
  exit 1
fi

SLUG=$(echo "$TAREA" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-//' -e 's/-$//' | cut -c 1-50)
SLUG="${SLUG:-proyecto}"
PROJECT_DIR="$PROJECTS_DIR/$SLUG"

if [ "$UNICO" -eq 1 ] && [ -e "$PROJECT_DIR" ]; then
  SUFFIX="$(date +%Y%m%dT%H%M%S)"
  PROJECT_DIR="$PROJECTS_DIR/$SLUG-$SUFFIX"
  intento=1
  while [ -e "$PROJECT_DIR" ]; do
    PROJECT_DIR="$PROJECTS_DIR/$SLUG-$SUFFIX-$intento"
    intento=$((intento + 1))
  done
fi

mkdir -p "$PROJECT_DIR"

echo "# Solicitud original" > "$PROJECT_DIR/SOLICITUD.md"
echo "" >> "$PROJECT_DIR/SOLICITUD.md"
echo "$TAREA" >> "$PROJECT_DIR/SOLICITUD.md"

echo "$PROJECT_DIR"
