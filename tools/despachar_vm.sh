#!/usr/bin/env bash
# Herramienta 3: sincronizar y ejecutar con Pi en la VM correspondiente al rol.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT/tools"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$ROOT/vms.json}"
ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despachar_vm.sh <rol> <directorio_proyecto> \"Tarea\"" >&2
  exit 1
fi
[[ "$ROLE" =~ ^[a-z0-9-]+$ ]] || { echo "Error: rol no válido." >&2; exit 1; }
[ -d "$PROJECT_DIR" ] || { echo "Error: no existe '$PROJECT_DIR'." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }

SHELL_QUOTE() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
GET_VM_FIELD() {
  jq -er --arg profile "$1" --arg field "$2" '.[$profile][$field]' "$VMS_CONF" 2>/dev/null || true
}

perfiles=()
while IFS= read -r profile; do
  [ -n "$profile" ] && perfiles+=("$profile")
done < <(jq -r --arg role "$ROLE" '
  to_entries[] |
  select(.value.stack == $role and .value.engine == "pi" and .value.dispatch_enabled == true) |
  .key
' "$VMS_CONF")

if [ "${#perfiles[@]}" -eq 0 ]; then
  echo "Error: no existe una VM Pi habilitada para el rol '$ROLE'." >&2
  echo "Configura una con ./tools/provisionar_vm_pi.sh <perfil-vm>." >&2
  exit 1
fi
if [ "${#perfiles[@]}" -gt 1 ]; then
  echo "Error: hay varias VMs Pi habilitadas para '$ROLE': ${perfiles[*]}." >&2
  echo "Deja dispatch_enabled=true en un solo perfil por rol." >&2
  exit 1
fi

PROFILE="${perfiles[0]}"
ip="$(GET_VM_FIELD "$PROFILE" ip)"
user="$(GET_VM_FIELD "$PROFILE" user)"
workspace="$(GET_VM_FIELD "$PROFILE" workspace)"
remote_agent="$(GET_VM_FIELD "$PROFILE" remote_agent)"
pi_harness="$(GET_VM_FIELD "$PROFILE" pi_harness)"
pi_provider="$(GET_VM_FIELD "$PROFILE" pi_provider)"
pi_model="$(GET_VM_FIELD "$PROFILE" pi_model)"
node_version="$(GET_VM_FIELD "$PROFILE" node_version)"
[ -n "$pi_harness" ] || pi_harness="/home/$user/.local/bin/pi-harness"
[ -n "$pi_provider" ] || pi_provider="openai-codex"
[ -n "$pi_model" ] || pi_model="gpt-5.4-mini"

for value in "$ip" "$user" "$workspace" "$remote_agent" "$node_version"; do
  [ -n "$value" ] || { echo "Error: configuración Pi incompleta para '$PROFILE'." >&2; exit 1; }
done
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || {
  echo "Error: usuario o dirección SSH no válidos para '$PROFILE'." >&2; exit 1;
}
[[ "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]] || {
  echo "Error: remote_agent debe permanecer dentro de /home/<usuario>/agentes/." >&2; exit 1;
}

# La VM consulta Git antes de ejecutar; la Mac no copia el agente en el despacho.
"$TOOLS_DIR/sincronizar_agente.sh" "$PROFILE" >&2

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

q_agent_dir="$(SHELL_QUOTE "$remote_agent/actual")"
q_agent_base="$(SHELL_QUOTE "$remote_agent")"
q_workspace="$(SHELL_QUOTE "$workspace")"
q_harness="$(SHELL_QUOTE "$pi_harness")"
q_role="$(SHELL_QUOTE "$ROLE")"
q_profile="$(SHELL_QUOTE "$PROFILE")"
q_provider="$(SHELL_QUOTE "$pi_provider")"
q_model="$(SHELL_QUOTE "$pi_model")"
q_node_path="$(SHELL_QUOTE "/home/$user/.nvm/versions/node/$node_version/bin:/home/$user/.local/bin")"

REMOTE_CMD="set -eu;
AGENT_DIR=$q_agent_dir;
AGENT_BASE=$q_agent_base;
WORKSPACE=$q_workspace;
PI_HARNESS=$q_harness;
ROLE=$q_role;
PROFILE=$q_profile;
PROVIDER=$q_provider;
MODEL=$q_model;
exec 8>\"\$AGENT_BASE/.actualizacion.lock\";
flock -s 8;
test -s \"\$AGENT_DIR/SKILL.md\";
test -x \"\$PI_HARNESS\" || { printf 'Error: falta pi-harness en %s. Provisiona %s.\n' \"\$PI_HARNESS\" \"\$PROFILE\" >&2; exit 1; };
VERSION=\$(cat \"\$AGENT_DIR/.agent-version\");
AGENT_RESOLVED=\$(readlink -f \"\$AGENT_DIR\");
GIT_COMMIT=\$(cat \"\$AGENT_DIR/.git-commit\" 2>/dev/null || true);
SKILL_SHA256=\$(sha256sum \"\$AGENT_DIR/SKILL.md\" | awk '{print \$1}');
TAREA=\$(cat);
export PATH=$q_node_path:\"\$PATH\";
PI_BIN=\$(command -v pi || true);
PI_VERSION=\$(pi --version 2>/dev/null | head -n 1 || true);
test -n \"\$PI_BIN\" || { echo 'Error: Pi no está disponible en PATH.' >&2; exit 1; };
printf 'PERFIL_VM: %s\n' \"\$PROFILE\" >&2;
printf 'AGENTE_RESUELTO: %s\n' \"\$AGENT_RESOLVED\" >&2;
printf 'VERSION_AGENTE: %s\n' \"\$VERSION\" >&2;
printf 'COMMIT_AGENTE: %s\n' \"\$GIT_COMMIT\" >&2;
printf 'SHA256_SKILL: %s\n' \"\$SKILL_SHA256\" >&2;
printf 'WORKSPACE_REMOTO: %s\n' \"\$WORKSPACE\" >&2;
printf 'PI_HARNESS_REMOTO: %s\n' \"\$PI_HARNESS\" >&2;
printf 'PI_BIN: %s\n' \"\$PI_BIN\" >&2;
printf 'PI_VERSION: %s\n' \"\$PI_VERSION\" >&2;
printf '%s\n' \"\$TAREA\" | \"\$PI_HARNESS\" start --role \"\$ROLE\" --workspace \"\$WORKSPACE\" --agent-dir \"\$AGENT_DIR\" --backend auto --provider \"\$PROVIDER\" --model \"\$MODEL\" --task -"

LOG_FILE="$PROJECT_DIR/${ROLE}_output.log"
echo "▶️ Ejecutando con Pi '$ROLE' mediante '$PROFILE' ($user@$ip)..." >&2
{
  echo "AGENTE_REMOTO: $remote_agent/actual"
  echo "PERFIL_VM_LOCAL: $PROFILE"
  echo "ROL: $ROLE"
  ssh "${SSH_OPTS[@]}" "$user@$ip" "$REMOTE_CMD" <<< "$TAREA"
} > "$LOG_FILE" 2>&1

"$TOOLS_DIR/generar_evidencia_agente.sh" "$ROLE" "$PROJECT_DIR" >/dev/null
echo "$LOG_FILE"
