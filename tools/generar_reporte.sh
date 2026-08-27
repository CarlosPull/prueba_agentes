#!/usr/bin/env bash
# Herramienta 4: Compilar los logs devueltos y generar AGENT_RUNNER.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

PROJECT_DIR="${1:-}"
TAREA="${2:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/generar_reporte.sh <directorio_proyecto> \"Tarea\""
  exit 1
fi

GET_ROLES() {
  if [ -f "$VMS_CONF" ]; then
    jq -r 'keys[]' "$VMS_CONF" 2>/dev/null || echo "backend frontend"
  else
    echo "backend frontend"
  fi
}

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  jq -er --arg role "$role" --arg field "$field" '.[$role][$field]' "$VMS_CONF" 2>/dev/null || true
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
    remote_agent=$(GET_VM_FIELD "$role" "remote_agent")
    log_file="$PROJECT_DIR/${role}_output.log"
    
    echo "## Rol: $role (VM: $ip)"
    echo "- Workspace: \`$workspace\`"
    if [ -n "$remote_agent" ]; then
      echo "- Agente remoto: \`$remote_agent/actual\`"
    else
      echo "- Agente remoto: sin despacho automatizado"
    fi
    echo ""
    echo "\`\`\`text"
    [ -f "$log_file" ] && cat "$log_file" || echo "Sin salida devuelta"
    echo "\`\`\`"
    echo ""
  done
} > "$REPORT"

echo "📄 Reporte consolidado guardado en: $REPORT"
