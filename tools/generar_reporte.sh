#!/usr/bin/env bash
# Consolida los eventos JSONL y errores de los despachos de agent-harness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

PROJECT_DIR="${1:-}"
TAREA="${2:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/generar_reporte.sh <directorio_proyecto> \"Tarea\"" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: el directorio de proyecto no existe: $PROJECT_DIR" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq es obligatorio para procesar la salida JSONL." >&2
  exit 1
fi

REPORT="$PROJECT_DIR/AGENT_HARNESS.md"
{
  echo "# Informe de ejecución de Agent Harness"
  echo ""
  echo "Fecha: $(date)"
  echo "Objetivo: $TAREA"
  echo ""

  while IFS= read -r role; do
    enabled=$(jq -r --arg role "$role" 'if .[$role] | has("enabled") then .[$role].enabled else true end' "$VMS_CONF")
    ip=$(jq -r --arg role "$role" '.[$role].ip // "sin IP"' "$VMS_CONF")
    workspace=$(jq -r --arg role "$role" '.[$role].workspace // "sin workspace"' "$VMS_CONF")
    log_file="$PROJECT_DIR/${role}_output.jsonl"
    error_file="$PROJECT_DIR/${role}_error.log"
    dispatch_file="$PROJECT_DIR/${role}_dispatch.json"

    echo "## Rol: $role (VM: $ip)"
    echo ""
    echo "- Workspace: \`$workspace\`"

    if [ "$enabled" != "true" ]; then
      reason=$(jq -r --arg role "$role" '.[$role].disabled_reason // "sin motivo"' "$VMS_CONF")
      echo "- Estado: deshabilitado"
      echo "- Motivo: $reason"
      echo ""
      continue
    fi

    if [ ! -f "$log_file" ]; then
      echo "- Estado: no despachado"
      echo ""
      continue
    fi

    finish=$(jq -Rsc '
      [split("\n")[] | try fromjson catch empty | select(.type == "run.finished")]
      | last // {}
    ' "$log_file")
    harness_status=$(jq -r '.status // "sin_evento_final"' <<<"$finish")
    harness_exit=$(jq -r '.exit_code // "desconocido"' <<<"$finish")
    ssh_exit="desconocido"
    [ -f "$dispatch_file" ] && ssh_exit=$(jq -r '.ssh_exit_code' "$dispatch_file")

    echo "- Estado harness: $harness_status"
    echo "- Código harness: $harness_exit"
    echo "- Código SSH: $ssh_exit"
    if grep -q 'RECHAZADO_FINAL\|RECHAZADO_ROL_INCORRECTO' "$log_file"; then
      echo "- Validación de dominio: RECHAZADO_FINAL"
    fi
    echo ""
    echo "### Salida del agente"
    echo ""
    echo '````text'
    jq -Rr '
      try fromjson catch empty
      | select(.type == "agent.output")
      | if has("data") then .data elif has("event") then (.event | tojson) else empty end
    ' "$log_file"
    echo '````'
    echo ""

    if [ -s "$error_file" ]; then
      echo "### Errores de transporte o arranque"
      echo ""
      echo '````text'
      cat "$error_file"
      echo '````'
      echo ""
    fi
  done < <(jq -r 'keys[]' "$VMS_CONF")
} >"$REPORT"

echo "📄 Reporte consolidado guardado en: $REPORT"
