#!/usr/bin/env bash
# Impide despachar dos veces el mismo rol, pero permite proyectos multirol.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/validar_y_despachar.sh <rol> <directorio_proyecto> \"Tarea\"" >&2
  exit 1
fi

if ! [[ "$ROLE" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  echo "Error: rol inválido '$ROLE'." >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: el directorio de proyecto no existe: $PROJECT_DIR" >&2
  exit 1
fi

LOCKS_DIR="$PROJECT_DIR/.ejecucion_locks"
LOCK_DIR="$LOCKS_DIR/$ROLE"
mkdir -p "$LOCKS_DIR"

# mkdir es atómico: dos procesos concurrentes no pueden adquirir el mismo rol.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "⛔ El rol '$ROLE' ya fue despachado o está en ejecución para este proyecto." >&2
  exit 1
fi

printf 'en_progreso\n' >"$LOCK_DIR/estado"

if "$TOOLS_DIR/despachar_vm.sh" "$ROLE" "$PROJECT_DIR" "$TAREA"; then
  printf 'completado\n' >"$LOCK_DIR/estado"
else
  exit_code=$?
  # Un fallo de transporte o del harness puede reintentarse de forma explícita.
  rm -f "$LOCK_DIR/estado"
  rmdir "$LOCK_DIR"
  exit "$exit_code"
fi
