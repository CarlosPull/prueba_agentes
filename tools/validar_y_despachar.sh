#!/usr/bin/env bash
# Herramienta Guardrail de Bloqueo Estricto: Impide físicamente cualquier re-despacho secundario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/validar_y_despachar.sh <rol> <directorio_proyecto> \"Tarea\""
  exit 1
fi

LOCK_FILE="$PROJECT_DIR/.ejecucion_lock"

# 1. Si ya se ejecutó un despacho previo en este proyecto, BLOQUEAR E INTERRUMPIR DE INMEDIATO
if [ -f "$LOCK_FILE" ]; then
  echo "------------------------------------------------------------" >&2
  echo "⛔ BLOQUEO DE SEGURIDAD ABSOLUTO:" >&2
  echo "Se detectó un intento de re-despacho secundario hacia el rol '$ROLE'." >&2
  echo "La política del sistema PROHÍBE estrictamente re-despachar o re-enrutar tareas a otros agentes." >&2
  echo "Ejecución interrumpida y cancelada." >&2
  echo "------------------------------------------------------------" >&2
  exit 1
fi

# Registrar candado de ejecución única para este proyecto
touch "$LOCK_FILE"

# 2. Invocar el despacho oficial hacia la VM por SSH STDIN
"$TOOLS_DIR/despachar_vm.sh" "$ROLE" "$PROJECT_DIR" "$TAREA"
