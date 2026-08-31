#!/usr/bin/env bash
# Herramienta 1: Diagnosticar conectividad SSH con las VMs configuradas en vms.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$ROOT/vms.json}"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

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

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"
[ -f "$HOME/.ssh/id_ed25519" ] && SSH_OPTS="$SSH_OPTS -i $HOME/.ssh/id_ed25519"

ROLES_SOLICITADOS=("$@")
ROL_SOLICITADO() {
  local profile="$1" stack="$2" solicitado
  [ "${#ROLES_SOLICITADOS[@]}" -gt 0 ] || return 0
  for solicitado in "${ROLES_SOLICITADOS[@]}"; do
    { [ "$solicitado" = "$stack" ] || [ "$solicitado" = "$profile" ]; } && return 0
  done
  return 1
}

echo "🔍 Diagnosticando conectividad SSH en todas las VMs configuradas..."
echo "------------------------------------------------------------"
index=1
errores=0
for role in $(GET_ROLES); do
  stack=$(GET_VM_FIELD "$role" "stack")
  ROL_SOLICITADO "$role" "$stack" || continue
  ip=$(GET_VM_FIELD "$role" "ip")
  user=$(GET_VM_FIELD "$role" "user")
  pi_harness=$(GET_VM_FIELD "$role" "pi_harness")
  node_version=$(GET_VM_FIELD "$role" "node_version")
  node_directory="$node_version"
  [[ "$node_directory" == v* ]] || node_directory="v$node_directory"
  [ -n "$pi_harness" ] || pi_harness="/home/$user/.local/bin/pi-harness"
  [ -z "$ip" ] && continue
  echo -n "$index. Perfil '$role', rol '$stack' ($user@$ip)... "
  if ssh $SSH_OPTS "$user@$ip" \
    "export PATH='/home/$user/.nvm/versions/node/$node_directory/bin:/home/$user/.local/bin':\"\$PATH\"; test -x '$pi_harness' && command -v pi >/dev/null && test -s '/home/$user/.pi/agent/auth.json'" \
    >/dev/null 2>&1; then
    echo "✓ SSH y Pi OK"
  else
    echo "❌ SSH, Pi/pi-harness o sesión autenticada no disponibles"
    errores=$((errores + 1))
  fi
  ((index++))
done

echo "------------------------------------------------------------"
[ "$errores" -eq 0 ] || exit 1
