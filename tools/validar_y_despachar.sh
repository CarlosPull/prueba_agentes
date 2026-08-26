#!/usr/bin/env bash
# Herramienta Guardrail de Defensa Estricta: Pre-validación de dominio y bloqueo físico de re-despachos.
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

TAREA_LOWER=$(echo "$TAREA" | tr '[:upper:]' '[:lower:]')

# 1. PRE-VALIDACIÓN DETERMINISTA DE DOMINIO (Barrera en el Script)
if [ "$ROLE" = "frontend" ] || [ "$ROLE" = "dev-front" ]; then
  if echo "$TAREA_LOWER" | grep -qE "php|artisan|laravel|eloquent|migration|migración|routes/api|composer|app/models|app/http"; then
    echo "------------------------------------------------------------" >&2
    echo "❌ TAREA RECHAZADA: INCOMPATIBILIDAD DE DOMINIO DETECTADA" >&2
    echo "El agente asignado '$ROLE' es estrictamente de Frontend (Vue 3 / UI)." >&2
    echo "La tarea contiene componentes pertenecientes al dominio de Backend (Laravel / SQL / PHP)." >&2
    echo "La ejecución ha sido cancelada de inmediato. No se re-despachará a ningún otro agente." >&2
    echo "------------------------------------------------------------" >&2
    exit 1
  fi
fi

if [ "$ROLE" = "backend" ] || [ "$ROLE" = "dev-back" ]; then
  if echo "$TAREA_LOWER" | grep -qE "vue|\.vue|vite|tailwind|npm run|vitest|components/ui|src/views|src/components"; then
    echo "------------------------------------------------------------" >&2
    echo "❌ TAREA RECHAZADA: INCOMPATIBILIDAD DE DOMINIO DETECTADA" >&2
    echo "El agente asignado '$ROLE' es estrictamente de Backend (PHP 8 / Laravel 13)." >&2
    echo "La tarea contiene componentes pertenecientes al dominio de Frontend (Vue 3 / TypeScript / UI)." >&2
    echo "La ejecución ha sido cancelada de inmediato. No se re-despachará a ningún otro agente." >&2
    echo "------------------------------------------------------------" >&2
    exit 1
  fi
fi

# 2. BLOQUEO FÍSICO DE RE-DESPACHO (Candado de Ejecución Única)
LOCK_FILE="$PROJECT_DIR/.ejecucion_lock"
if [ -f "$LOCK_FILE" ]; then
  echo "------------------------------------------------------------" >&2
  echo "⛔ BLOQUEO DE SEGURIDAD ABSOLUTO:" >&2
  echo "Se detectó un intento de re-despacho secundario hacia '$ROLE'." >&2
  echo "La política inquebrantable del sistema PROHÍBE re-despachar o re-enrutar tareas a otros agentes." >&2
  echo "Ejecución cancelada e interrumpida." >&2
  echo "------------------------------------------------------------" >&2
  exit 1
fi

touch "$LOCK_FILE"

# 3. Invocación limpia SSH
"$TOOLS_DIR/despachar_vm.sh" "$ROLE" "$PROJECT_DIR" "$TAREA"
