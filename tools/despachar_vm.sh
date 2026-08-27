#!/usr/bin/env bash
# Herramienta 3: sincronizar y ejecutar en la VM el agente correspondiente al rol.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"
VMS_CONF="$ROOT/vms.json"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despachar_vm.sh <rol> <directorio_proyecto> \"Tarea\"" >&2
  exit 1
fi

if [[ ! "$ROLE" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: el rol solo puede contener letras minúsculas, números y guiones." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  jq -er --arg role "$role" --arg field "$field" '.[$role][$field]' "$VMS_CONF" 2>/dev/null || true
}

SHELL_QUOTE() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

ip="$(GET_VM_FIELD "$ROLE" "ip")"
user="$(GET_VM_FIELD "$ROLE" "user")"
workspace="$(GET_VM_FIELD "$ROLE" "workspace")"
runner_bin="$(GET_VM_FIELD "$ROLE" "agent_runner")"
remote_agent="$(GET_VM_FIELD "$ROLE" "remote_agent")"

if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$workspace" ] || [ -z "$runner_bin" ] || [ -z "$remote_agent" ]; then
  echo "Error: configuración incompleta para el rol '$ROLE' en vms.json." >&2
  exit 1
fi

if [[ ! "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: remote_agent debe permanecer dentro de /home/<usuario>/agentes/." >&2
  exit 1
fi

if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Error: usuario o dirección SSH no válidos para el rol '$ROLE'." >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: no existe el directorio de proyecto '$PROJECT_DIR'." >&2
  exit 1
fi

# Todo despacho, incluso el directo, garantiza primero la versión remota del agente.
"$TOOLS_DIR/sincronizar_agente.sh" "$ROLE" >&2

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

q_agent_dir="$(SHELL_QUOTE "$remote_agent/actual")"
q_agent_base="$(SHELL_QUOTE "$remote_agent")"
q_workspace="$(SHELL_QUOTE "$workspace")"
q_runner="$(SHELL_QUOTE "$runner_bin")"
q_role="$(SHELL_QUOTE "$ROLE")"

REMOTE_CMD="set -eu;
AGENT_DIR=$q_agent_dir;
AGENT_BASE=$q_agent_base;
WORKSPACE=$q_workspace;
RUNNER_BIN=$q_runner;
ROLE=$q_role;
exec 8>\"\$AGENT_BASE/.actualizacion.lock\";
flock -s 8;
test -s \"\$AGENT_DIR/SKILL.md\";
VERSION=\$(cat \"\$AGENT_DIR/.agent-version\");
TAREA=\$(cat);
printf 'VERSION_AGENTE: %s\\n' \"\$VERSION\" >&2;
export PATH=\"\$PATH:/home/serveradmin/.nvm/versions/node/v24.19.0/bin:/home/serveradmin/.local/bin\";"

if [ -n "${OPENAI_API_KEY:-}" ]; then
  REMOTE_CMD="OPENAI_API_KEY=$(SHELL_QUOTE "$OPENAI_API_KEY"); export OPENAI_API_KEY; $REMOTE_CMD"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  REMOTE_CMD="ANTHROPIC_API_KEY=$(SHELL_QUOTE "$ANTHROPIC_API_KEY"); export ANTHROPIC_API_KEY; $REMOTE_CMD"
fi

REMOTE_CMD="$REMOTE_CMD
{
  cat \"\$AGENT_DIR/SKILL.md\";
  find -H \"\$AGENT_DIR\" -type f -name '*.md' ! -name 'SKILL.md' -print | LC_ALL=C sort | while IFS= read -r RECURSO; do
    RUTA_RELATIVA=\${RECURSO#\"\$AGENT_DIR/\"};
    printf '\\n---\\nRECURSO DEL AGENTE: %s\\n' \"\$RUTA_RELATIVA\";
    cat \"\$RECURSO\";
  done;
  printf '\\n---\\nCONTEXTO DE EJECUCIÓN REMOTA:\\n';
  printf 'Directorio del agente: %s\\n' \"\$AGENT_DIR\";
  printf 'Versión del agente: %s\\n' \"\$VERSION\";
  printf 'Los subagentes, referencias, memoria y scripts del rol están disponibles en ese directorio.\\n';
  printf '\\nREQUISITO O TAREA DE %s:\\n%s\\n' \"\$ROLE\" \"\$TAREA\";
} | \"\$RUNNER_BIN\" start --agent opencode --role \"\$ROLE\" --workspace \"\$WORKSPACE\" --backend auto --task -"

LOG_FILE="$PROJECT_DIR/${ROLE}_output.log"

echo "▶️ Ejecutando el agente remoto '$ROLE' ($user@$ip)..." >&2

{
  echo "AGENTE_REMOTO: $remote_agent/actual"
  echo "ROL: $ROLE"
  ssh "${SSH_OPTS[@]}" "$user@$ip" "$REMOTE_CMD" <<< "$TAREA"
} > "$LOG_FILE" 2>&1

echo "$LOG_FILE"
