#!/usr/bin/env bash
# Herramienta 4: compilar las ejecuciones Pi y su evidencia.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

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
    jq -r 'to_entries[] | select(.value.engine == "pi" and .value.dispatch_enabled == true) | .key' "$VMS_CONF"
  else
    echo "backend frontend"
  fi
}

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  jq -er --arg role "$role" --arg field "$field" '.[$role][$field]' "$VMS_CONF" 2>/dev/null || true
}

EVIDENCE="$PROJECT_DIR/EVIDENCIA_AGENTES.md"
{
  echo "# Evidencia de agentes Pi remotos utilizados"
  echo ""
  echo "Metadatos emitidos dentro de cada VM durante la ejecución por SSH."
  echo ""
  for evidence_file in "$PROJECT_DIR"/EVIDENCIA_*.md; do
    [ "$evidence_file" != "$EVIDENCE" ] || continue
    [ ! -s "$evidence_file" ] || cat "$evidence_file"
  done
} > "$EVIDENCE"

REPORT="$PROJECT_DIR/REPORTE_PI.md"
{
  echo "# Informe de Ejecución Distribuida con Pi"
  echo ""
  echo "Fecha: $(date)"
  echo "Objetivo: $TAREA"
  echo ""
  if [ -f "$PROJECT_DIR/REQUISITOS.md" ]; then
    cat "$PROJECT_DIR/REQUISITOS.md"
    echo ""
  fi
  for log_file in "$PROJECT_DIR"/*_output.log; do
    [ -f "$log_file" ] || continue
    profile="$(sed -n 's/^PERFIL_VM: //p; s/^PERFIL_VM_LOCAL: //p' "$log_file" | head -n 1)"
    role="$(sed -n 's/^ROL: //p' "$log_file" | head -n 1)"
    repository="$(sed -n 's/^REPOSITORIO: //p' "$log_file" | head -n 1)"
    module="$(sed -n 's/^MODULO: //p' "$log_file" | head -n 1)"
    ip=$(GET_VM_FIELD "$profile" "ip")
    workspace="$(sed -n 's/^WORKSPACE_REMOTO: //p' "$log_file" | head -n 1)"
    remote_agent=$(GET_VM_FIELD "$profile" "remote_agent")
    git_branch=$(GET_VM_FIELD "$profile" "git_branch")
    git_agent_path=$(GET_VM_FIELD "$profile" "git_agent_path")
    echo "## Rol: $role (perfil: $profile, módulo: ${module:-n/d}, VM: $ip)"
    echo "- Workspace: \`$workspace\`"
    echo "- Repositorio: \`${repository:-no disponible}\`"
    if [ -n "$remote_agent" ]; then
      echo "- Agente remoto: \`$remote_agent/actual\`"
      echo "- Fuente Git: \`$git_branch:$git_agent_path\`"
    else
      echo "- Agente remoto: sin despacho automatizado"
    fi
    echo ""
    echo "\`\`\`text"
    cat "$log_file"
    echo "\`\`\`"
    echo ""
  done
} > "$REPORT"

echo "📄 Reporte consolidado guardado en: $REPORT"
