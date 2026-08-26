#!/usr/bin/env bash
# Diagnostica SSH, agent-harness, el motor y el sandbox de cada VM habilitada.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
fi

SSH_OPTS=(
  -n
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=yes
)
[ -f "$HOME/.ssh/id_ed25519" ] && SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

echo "🔍 Diagnosticando VMs y agent-harness..."
echo "------------------------------------------------------------"

failures=0
index=1
while IFS= read -r role; do
  enabled=$(jq -r --arg role "$role" 'if .[$role] | has("enabled") then .[$role].enabled else true end' "$VMS_CONF")
  if [ "$enabled" != "true" ]; then
    reason=$(jq -r --arg role "$role" '.[$role].disabled_reason // "sin motivo"' "$VMS_CONF")
    echo "$index. Rol '$role': omitido ($reason)"
    index=$((index + 1))
    continue
  fi

  ip=$(jq -er --arg role "$role" '.[$role].ip' "$VMS_CONF")
  user=$(jq -er --arg role "$role" '.[$role].user' "$VMS_CONF")
  harness_bin=$(jq -er --arg role "$role" '.[$role].harness_bin' "$VMS_CONF")
  engine_bin_dir=$(jq -er --arg role "$role" '.[$role].engine_bin_dir' "$VMS_CONF")
  engine=$(jq -er --arg role "$role" '.[$role].engine' "$VMS_CONF")

  if ! [[ "$harness_bin" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    ! [[ "$engine_bin_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    ! [[ "$engine" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "$index. Rol '$role' ($user@$ip): ❌ configuración insegura"
    failures=$((failures + 1))
    index=$((index + 1))
    continue
  fi

  echo -n "$index. Rol '$role' ($user@$ip)... "
  if doctor=$(ssh "${SSH_OPTS[@]}" "$user@$ip" \
    "PATH=$engine_bin_dir:\$PATH; export PATH; test -x $harness_bin && $harness_bin doctor --engine $engine" 2>/dev/null); then
    if jq -e '.ready == true' >/dev/null 2>&1 <<<"$doctor"; then
      sandbox=$(jq -r '.selected_sandbox' <<<"$doctor")
      echo "✓ listo (sandbox: $sandbox, engine: $engine)"
    else
      echo "❌ doctor respondió que la VM no está lista"
      failures=$((failures + 1))
    fi
  else
    echo "❌ SSH, binario o doctor falló"
    failures=$((failures + 1))
  fi
  index=$((index + 1))
done < <(jq -r 'keys[]' "$VMS_CONF")

echo "------------------------------------------------------------"
if [ "$failures" -ne 0 ]; then
  echo "❌ Diagnóstico finalizado con $failures VM(s) no disponibles." >&2
  exit 1
fi
echo "✅ Todas las VMs habilitadas están listas."
