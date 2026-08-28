#!/usr/bin/env bash
# Construye evidencia local a partir de metadatos emitidos por la ejecución SSH remota.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ]; then
  echo "Uso: ./tools/generar_evidencia_agente.sh <rol> <directorio_proyecto>" >&2
  exit 1
fi

LOG_FILE="$PROJECT_DIR/${ROLE}_output.log"
EVIDENCE_FILE="$PROJECT_DIR/EVIDENCIA_AGENTES.md"

if [ ! -s "$LOG_FILE" ]; then
  echo "Error: no existe una bitácora para construir evidencia: $LOG_FILE" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

VALOR_LOG() {
  local clave="$1"
  sed -n "s/^${clave}: //p" "$LOG_FILE" | head -n 1
}

ip="$(jq -r --arg role "$ROLE" '.[$role].ip // ""' "$VMS_CONF")"
user="$(jq -r --arg role "$ROLE" '.[$role].user // ""' "$VMS_CONF")"
agente="$(VALOR_LOG "AGENTE_REMOTO")"
agente_resuelto="$(VALOR_LOG "AGENTE_RESUELTO")"
version="$(VALOR_LOG "VERSION_AGENTE")"
commit="$(VALOR_LOG "COMMIT_AGENTE")"
skill_sha256="$(VALOR_LOG "SHA256_SKILL")"
workspace="$(VALOR_LOG "WORKSPACE_REMOTO")"
runner="$(VALOR_LOG "AGENT_RUNNER_REMOTO")"
opencode_bin="$(VALOR_LOG "OPENCODE_BIN")"
opencode_version="$(VALOR_LOG "OPENCODE_VERSION")"
run_id="$(VALOR_LOG "run_id")"
manifest="$(VALOR_LOG "manifest")"

if [ -z "$agente" ] || [ -z "$version" ] || [ -z "$run_id" ]; then
  echo "Error: la salida remota no contiene agente, versión y run_id suficientes para demostrar la ejecución." >&2
  exit 1
fi

if [ ! -f "$EVIDENCE_FILE" ]; then
  {
    echo "# Evidencia de agentes remotos utilizados"
    echo ""
    echo "Este archivo se genera desde metadatos emitidos dentro de cada VM durante la ejecución por SSH."
    echo ""
  } > "$EVIDENCE_FILE"
fi

{
  echo "## Ejecución del rol: $ROLE"
  echo ""
  echo "- Fecha registrada por el orquestador: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- VM: \`$user@$ip\`"
  echo "- Agente solicitado: \`$agente\`"
  echo "- Agente resuelto en la VM: \`${agente_resuelto:-no disponible}\`"
  echo "- Versión del agente: \`$version\`"
  echo "- Commit Git fuente del agente: \`${commit:-no disponible}\`"
  echo "- SHA-256 de SKILL.md: \`${skill_sha256:-no disponible}\`"
  echo "- Workspace remoto: \`${workspace:-no disponible}\`"
  echo "- Agent Runner remoto: \`${runner:-no disponible}\`"
  echo "- OpenCode remoto: \`${opencode_bin:-no disponible}\`"
  echo "- Versión de OpenCode: \`${opencode_version:-no disponible}\`"
  echo "- Run ID: \`$run_id\`"
  echo "- Manifiesto remoto: \`${manifest:-no disponible}\`"
  echo "- Bitácora local: \`${ROLE}_output.log\`"
  echo ""
} >> "$EVIDENCE_FILE"

echo "$EVIDENCE_FILE"
