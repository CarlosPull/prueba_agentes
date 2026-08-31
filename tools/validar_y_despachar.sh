#!/usr/bin/env bash
# Herramienta Guardrail de Defensa Estricta: Pre-validación de dominio y bloqueo físico de re-despachos.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"
MODO_FULLSTACK="${4:-}"
PROFILE=""
REPOSITORY=""
DISPATCH_ID="$ROLE"

shift "$([ "$#" -ge 3 ] && echo 3 || echo 0)"
MODO_FULLSTACK=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fullstack-confirmado) MODO_FULLSTACK="$1"; shift ;;
    --profile) [ "$#" -ge 2 ] || exit 1; PROFILE="$2"; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || exit 1; REPOSITORY="$2"; shift 2 ;;
    --dispatch-id) [ "$#" -ge 2 ] || exit 1; DISPATCH_ID="$2"; shift 2 ;;
    *) echo "Error: opción no reconocida '$1'." >&2; exit 1 ;;
  esac
done

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/validar_y_despachar.sh <rol> <directorio_proyecto> \"Tarea\" [--fullstack-confirmado] [--profile perfil --repository repo --dispatch-id id]"
  exit 1
fi

[[ "$DISPATCH_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Error: dispatch-id no válido." >&2; exit 1; }

if [ "$MODO_FULLSTACK" = "--fullstack-confirmado" ]; then
  ROLE_UPPER="$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')"
  PREFIJO_CATEGORIZADO="Solicitud categorizada para $ROLE_UPPER."
  if { [ "$ROLE" != "backend" ] && [ "$ROLE" != "frontend" ]; } ||
     { [[ "$TAREA" != "Solicitud Full-Stack explícita."* ]] &&
       [[ "$TAREA" != "$PREFIJO_CATEGORIZADO"* ]]; }; then
    echo "Error: el modo Full-Stack solo acepta subtareas internas de backend o frontend generadas por tools/orquestar.sh." >&2
    exit 1
  fi
fi

TAREA_LOWER=$(echo "$TAREA" | tr '[:upper:]' '[:lower:]')

# 1. PRE-VALIDACIÓN DETERMINISTA DE DOMINIO (Barrera en el Script)
if [ -z "$MODO_FULLSTACK" ] && { [ "$ROLE" = "frontend" ] || [ "$ROLE" = "dev-front" ]; }; then
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

if [ -z "$MODO_FULLSTACK" ] && { [ "$ROLE" = "backend" ] || [ "$ROLE" = "dev-back" ]; }; then
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
LOCK_FILE="$PROJECT_DIR/.ejecucion_lock.$DISPATCH_ID"
if [ -f "$LOCK_FILE" ]; then
  echo "------------------------------------------------------------" >&2
  echo "⛔ BLOQUEO DE SEGURIDAD ABSOLUTO:" >&2
  echo "Ya existe una ejecución registrada para el rol '$ROLE' en este proyecto." >&2
  echo "La política del sistema prohíbe repetir un despacho ya ejecutado." >&2
  echo "Ejecución cancelada e interrumpida." >&2
  echo "------------------------------------------------------------" >&2
  exit 1
fi

touch "$LOCK_FILE"

# 3. Invocación limpia SSH
dispatch_args=()
[ -z "$PROFILE" ] || dispatch_args+=(--profile "$PROFILE")
[ -z "$REPOSITORY" ] || dispatch_args+=(--repository "$REPOSITORY")
dispatch_args+=(--dispatch-id "$DISPATCH_ID")
"$TOOLS_DIR/despachar_vm.sh" "$ROLE" "$PROJECT_DIR" "$TAREA" "${dispatch_args[@]}"
