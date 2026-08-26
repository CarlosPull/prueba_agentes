#!/usr/bin/env bash
# Despacha una ejecución de agent-harness a la VM configurada para un rol.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/skills"
VMS_CONF="$ROOT/vms.json"

ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despachar_vm.sh <rol> <directorio_proyecto> \"Tarea\"" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq es obligatorio para leer vms.json de forma segura." >&2
  exit 1
fi

if ! [[ "$ROLE" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  echo "Error: rol inválido '$ROLE'." >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: el directorio de proyecto no existe: $PROJECT_DIR" >&2
  exit 1
fi

VM_JSON=$(jq -ce --arg role "$ROLE" '.[$role] // empty' "$VMS_CONF") || {
  echo "Error: no se encontró la configuración para el rol '$ROLE' en vms.json." >&2
  exit 1
}

VM_FIELD() {
  local field="$1"
  jq -er --arg field "$field" '.[$field] // empty' <<<"$VM_JSON"
}

if [ "$(jq -r 'if has("enabled") then .enabled else true end' <<<"$VM_JSON")" != "true" ]; then
  reason=$(jq -r '.disabled_reason // "rol deshabilitado"' <<<"$VM_JSON")
  echo "Error: el rol '$ROLE' está deshabilitado: $reason" >&2
  exit 1
fi

ip=$(VM_FIELD ip)
user=$(VM_FIELD user)
workspace=$(VM_FIELD workspace)
harness_bin=$(VM_FIELD harness_bin)
engine_bin_dir=$(VM_FIELD engine_bin_dir)
engine=$(VM_FIELD engine)
agent=$(VM_FIELD agent)
skill=$(VM_FIELD skill)
policy_role=$(VM_FIELD policy_role)
sandbox=$(VM_FIELD sandbox)
credentials=$(VM_FIELD credentials)
output=$(VM_FIELD output)

for token in "$ROLE" "$engine" "$agent" "$skill" "$policy_role" "$sandbox" "$credentials" "$output"; do
  if ! [[ "$token" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "Error: valor inseguro en vms.json para '$ROLE': $token" >&2
    exit 1
  fi
done

if [ "$output" != "jsonl" ]; then
  echo "Error: el orquestador requiere output=jsonl para interpretar run.finished." >&2
  exit 1
fi

for remote_path in "$workspace" "$harness_bin" "$engine_bin_dir"; do
  if ! [[ "$remote_path" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: ruta remota insegura en vms.json: $remote_path" >&2
    exit 1
  fi
done

SKILL_FILE="$SKILLS_DIR/$skill/SKILL.md"
[ ! -f "$SKILL_FILE" ] && SKILL_FILE="$SKILLS_DIR/$skill/AGENTE.md"

ANALYST_FILE=""
if [ -f "$SKILLS_DIR/$skill/subagentes/analista.md" ]; then
  ANALYST_FILE="$SKILLS_DIR/$skill/subagentes/analista.md"
fi

MEMORY_FILE=""
if [ -f "$SKILLS_DIR/$skill/memory.md" ]; then
  MEMORY_FILE="$SKILLS_DIR/$skill/memory.md"
fi

PROMPT_ROLE="TAREA ASIGNADA AL ROL $ROLE:
$TAREA"
if [ -f "$SKILL_FILE" ]; then
  PROMPT_ROLE="INSTRUCCIONES DEL ROL:
$(cat "$SKILL_FILE")"
  if [ -n "$ANALYST_FILE" ]; then
    PROMPT_ROLE="$PROMPT_ROLE

---
VALIDACIÓN DE DOMINIO OBLIGATORIA ANTES DE MODIFICAR ARCHIVOS:
$(cat "$ANALYST_FILE")"
  fi
  if [ -n "$MEMORY_FILE" ]; then
    PROMPT_ROLE="$PROMPT_ROLE

---
MEMORIA DEL ROL:
$(cat "$MEMORY_FILE")"
  fi
  for context_file in \
    "$SKILLS_DIR/$skill"/references/*.md \
    "$SKILLS_DIR/$skill"/subagentes/*.md; do
    [ -f "$context_file" ] || continue
    [ "$context_file" = "$ANALYST_FILE" ] && continue
    PROMPT_ROLE="$PROMPT_ROLE

---
CONTEXTO COMPLEMENTARIO ($(basename "$context_file")):
$(cat "$context_file")"
  done
  PROMPT_ROLE="$PROMPT_ROLE

---
TAREA ASIGNADA AL ROL $ROLE:
$TAREA"
fi

LOG_FILE="$PROJECT_DIR/${ROLE}_output.jsonl"
ERROR_FILE="$PROJECT_DIR/${ROLE}_error.log"
STATUS_FILE="$PROJECT_DIR/${ROLE}_dispatch.json"

SSH_OPTS=(
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=yes
)
[ -f "$HOME/.ssh/id_ed25519" ] && SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

# Los valores interpolados fueron restringidos arriba a tokens o rutas absolutas.
# Las claves y el prompt viajan por STDIN cifrado, no dentro de argv del proceso SSH.
REMOTE_COMMAND="
IFS= read -r OPENAI_API_KEY
IFS= read -r ANTHROPIC_API_KEY
PATH=$engine_bin_dir:\$PATH
export PATH
set -- $harness_bin run --engine $engine
if [ $engine = opencode ]; then set -- \"\$@\" --agent $agent; fi
set -- \"\$@\" --role $policy_role --workspace $workspace --sandbox $sandbox --credentials $credentials --output $output
if [ -n \"\$OPENAI_API_KEY\" ]; then export OPENAI_API_KEY; set -- \"\$@\" --pass-env OPENAI_API_KEY; fi
if [ -n \"\$ANTHROPIC_API_KEY\" ]; then export ANTHROPIC_API_KEY; set -- \"\$@\" --pass-env ANTHROPIC_API_KEY; fi
PROMPT=\$(cat)
exec \"\$@\" --prompt \"\$PROMPT\"
"

echo "▶️ Despachando '$ROLE' con agent-harness en $user@$ip..." >&2

set +e
{
  printf '%s\n' "${OPENAI_API_KEY:-}"
  printf '%s\n' "${ANTHROPIC_API_KEY:-}"
  printf '%s' "$PROMPT_ROLE"
} | ssh "${SSH_OPTS[@]}" "$user@$ip" "$REMOTE_COMMAND" >"$LOG_FILE" 2>"$ERROR_FILE"
exit_code=$?
set -e

jq -n \
  --arg role "$ROLE" \
  --arg policy_role "$policy_role" \
  --arg log "$LOG_FILE" \
  --arg error_log "$ERROR_FILE" \
  --argjson exit_code "$exit_code" \
  '{role: $role, policy_role: $policy_role, ssh_exit_code: $exit_code, log: $log, error_log: $error_log}' \
  >"$STATUS_FILE"

if [ "$exit_code" -ne 0 ]; then
  echo "Error: agent-harness terminó con código $exit_code. Revisa $LOG_FILE y $ERROR_FILE." >&2
  exit "$exit_code"
fi

echo "$LOG_FILE"
