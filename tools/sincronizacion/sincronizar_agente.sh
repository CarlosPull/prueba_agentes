#!/usr/bin/env bash
# Solicita a la VM que consulte y active su rama Git; no copia archivos desde la Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
ROLE="${1:-}"

if [ -z "$ROLE" ]; then
  echo "Uso: ./tools/sincronizar_agente.sh <rol>" >&2
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

ip="$(GET_VM_FIELD "$ROLE" "ip")"
user="$(GET_VM_FIELD "$ROLE" "user")"
remote_agent="$(GET_VM_FIELD "$ROLE" "remote_agent")"

if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$remote_agent" ]; then
  echo "Error: configuración Git incompleta para el rol '$ROLE' en vms.json." >&2
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

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "test -x '$remote_agent/actualizar_desde_git.sh' || { echo 'Error: ejecuta primero ./tools/instalar_actualizacion_git.sh $ROLE' >&2; exit 1; }; '$remote_agent/actualizar_desde_git.sh'"
