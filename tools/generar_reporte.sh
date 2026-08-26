#!/usr/bin/env bash
# Herramienta 4: Compilar los logs devueltos y generar AGENT_RUNNER.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

PROJECT_DIR="${1:-}"
TAREA="${2:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/generar_reporte.sh <directorio_proyecto> \"Tarea\""
  exit 1
fi

GET_ROLES() {
  if [ -f "$VMS_CONF" ]; then
    python3 -c "import json; print(' '.join(json.load(open('$VMS_CONF')).keys()))" 2>/dev/null || echo "backend frontend"
  else
    echo "backend frontend"
  fi
}

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  python3 -c "import json; print(json.load(open('$VMS_CONF'))['$role']['$field'])" 2>/dev/null || echo ""
}

REPORT="$PROJECT_DIR/AGENT_RUNNER.md"
{
  echo "# Informe de Ejecución de Agent Runner"
  echo ""
  echo "Fecha: $(date)"
  echo "Objetivo: $TAREA"
  echo ""
  for role in $(GET_ROLES); do
    ip=$(GET_VM_FIELD "$role" "ip")
    workspace=$(GET_VM_FIELD "$role" "workspace")
    log_file="$PROJECT_DIR/${role}_output.log"
    
    echo "## Rol: $role (VM: $ip)"
    echo "- Workspace: \`$workspace\`"
    echo ""
    echo "\`\`\`text"
    [ -f "$log_file" ] && cat "$log_file" || echo "Sin salida devuelta"
    echo "\`\`\`"
    echo ""
  done
} > "$REPORT"

echo "📄 Reporte consolidado guardado en: $REPORT"
