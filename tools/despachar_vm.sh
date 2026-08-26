#!/usr/bin/env bash
# Herramienta 3: Despachar la ejecución de agent-runner a una VM específica por su rol
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/skills"
VMS_CONF="$ROOT/vms.json"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despachar_vm.sh <rol> <directorio_proyecto> \"Tarea\""
  exit 1
fi

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  python3 -c "import json; print(json.load(open('$VMS_CONF'))['$role']['$field'])" 2>/dev/null || echo ""
}

ip=$(GET_VM_FIELD "$ROLE" "ip")
user=$(GET_VM_FIELD "$ROLE" "user")
workspace=$(GET_VM_FIELD "$ROLE" "workspace")
runner_bin=$(GET_VM_FIELD "$ROLE" "agent_runner")

if [ -z "$ip" ]; then
  echo "Error: No se encontró la configuración para el rol '$ROLE' en vms.json" >&2
  exit 1
fi

# Cargar instrucciones de la habilidad (skills/<role>/SKILL.md o AGENTE.md)
SKILL_FILE="$SKILLS_DIR/dev-$ROLE/SKILL.md"
[ ! -f "$SKILL_FILE" ] && SKILL_FILE="$SKILLS_DIR/$ROLE/SKILL.md"
[ ! -f "$SKILL_FILE" ] && SKILL_FILE="$SKILLS_DIR/$ROLE/AGENTE.md"

PROMPT_ROLE="Tarea: $TAREA"
if [ -f "$SKILL_FILE" ]; then
  PROMPT_ROLE="$(cat "$SKILL_FILE")

---
REQUISITO O TAREA DE $ROLE:
$TAREA"
fi

ENV_EXPORTS="export PATH=\$PATH:/home/serveradmin/.nvm/versions/node/v24.19.0/bin:/home/serveradmin/.local/bin;"
if [ -n "${OPENAI_API_KEY:-}" ]; then
  ENV_EXPORTS="export OPENAI_API_KEY='$OPENAI_API_KEY'; $ENV_EXPORTS"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ENV_EXPORTS="export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'; $ENV_EXPORTS"
fi

LOG_FILE="$PROJECT_DIR/${ROLE}_output.log"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
[ -f "$HOME/.ssh/id_ed25519" ] && SSH_OPTS="$SSH_OPTS -i $HOME/.ssh/id_ed25519"

echo "▶️ Despachando a la VM '$ROLE' ($user@$ip)..." >&2
ssh $SSH_OPTS "$user@$ip" \
  "$ENV_EXPORTS $runner_bin start --agent opencode --role $ROLE --workspace $workspace --backend auto --task '$PROMPT_ROLE'" \
  > "$LOG_FILE" 2>&1


echo "$LOG_FILE"
