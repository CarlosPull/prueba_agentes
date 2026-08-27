#!/usr/bin/env bash
# Herramienta 1: Diagnosticar conectividad SSH con las VMs configuradas en vms.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

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

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"
[ -f "$HOME/.ssh/id_ed25519" ] && SSH_OPTS="$SSH_OPTS -i $HOME/.ssh/id_ed25519"

echo "🔍 Diagnosticando conectividad SSH en todas las VMs configuradas..."
echo "------------------------------------------------------------"
index=1
for role in $(GET_ROLES); do
  ip=$(GET_VM_FIELD "$role" "ip")
  user=$(GET_VM_FIELD "$role" "user")
  [ -z "$ip" ] && continue
  echo -n "$index. Rol '$role' ($user@$ip)... "
  if ssh $SSH_OPTS "$user@$ip" "echo OK" >/dev/null 2>&1; then
    echo "✓ SSH OK"
  else
    echo "❌ Fallo de conexión SSH"
  fi
  ((index++))
done

echo "------------------------------------------------------------"
