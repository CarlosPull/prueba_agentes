#!/usr/bin/env bash
# Sincroniza el agente de un rol con su VM y activa la nueva versión atómicamente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"

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
command -v rsync >/dev/null 2>&1 || {
  echo "Error: rsync es obligatorio para sincronizar agentes." >&2
  exit 1
}
command -v shasum >/dev/null 2>&1 || {
  echo "Error: shasum es obligatorio para versionar agentes." >&2
  exit 1
}

GET_VM_FIELD() {
  local role="$1"
  local field="$2"
  jq -er --arg role "$role" --arg field "$field" '.[$role][$field]' "$VMS_CONF" 2>/dev/null || true
}

CALCULAR_HUELLA() {
  local agent_dir="$1"
  local modo

  (
    cd "$agent_dir"
    find . -type f ! -name '.agent-version' -print \
      | LC_ALL=C sort \
      | while IFS= read -r archivo; do
          if modo="$(stat -f '%Lp' "$archivo" 2>/dev/null)"; then
            :
          else
            modo="$(stat -c '%a' "$archivo")"
          fi
          printf '%s %s\n' "$modo" "$archivo"
          shasum -a 256 "$archivo"
        done
  ) | shasum -a 256 | awk '{print $1}'
}

ip="$(GET_VM_FIELD "$ROLE" "ip")"
user="$(GET_VM_FIELD "$ROLE" "user")"
local_agent_rel="$(GET_VM_FIELD "$ROLE" "local_agent")"
remote_agent="$(GET_VM_FIELD "$ROLE" "remote_agent")"

if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$local_agent_rel" ] || [ -z "$remote_agent" ]; then
  echo "Error: configuración de agente incompleta para el rol '$ROLE' en vms.json." >&2
  exit 1
fi

if [[ "$local_agent_rel" != skills/* ]] || [[ "$local_agent_rel" == *".."* ]]; then
  echo "Error: local_agent debe ser una ruta relativa dentro de skills/." >&2
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

local_agent="$ROOT/$local_agent_rel"
if [ ! -s "$local_agent/SKILL.md" ]; then
  echo "Error: no existe un SKILL.md válido para '$ROLE' en '$local_agent'." >&2
  exit 1
fi

if [ "$(sed -n '1p' "$local_agent/SKILL.md")" != "---" ]; then
  echo "Error: '$local_agent/SKILL.md' no comienza con YAML Frontmatter." >&2
  exit 1
fi

huella="$(CALCULAR_HUELLA "$local_agent")"
remote_release="$remote_agent/.versiones/$huella"
remote_tmp="$remote_agent/.versiones/.${huella}.tmp.$$"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

remote_version="$(
  ssh "${SSH_OPTS[@]}" "$user@$ip" \
    "test -f '$remote_agent/actual/.agent-version' && cat '$remote_agent/actual/.agent-version' || true"
)"

if [ "$remote_version" = "$huella" ]; then
  echo "✓ Agente '$ROLE' ya está actualizado ($huella)."
  exit 0
fi

echo "🔄 Sincronizando agente '$ROLE' con $user@$ip..."

ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "mkdir -p '$remote_agent/.versiones' && rm -rf '$remote_tmp' && mkdir -p '$remote_tmp'"

rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
  "$local_agent/" "$user@$ip:$remote_tmp/"

ssh "${SSH_OPTS[@]}" "$user@$ip" bash -s -- \
  "$remote_agent" "$remote_tmp" "$remote_release" "$huella" <<'REMOTE_SCRIPT'
set -euo pipefail

remote_agent="$1"
remote_tmp="$2"
remote_release="$3"
huella="$4"

test -s "$remote_tmp/SKILL.md"
test "$(sed -n '1p' "$remote_tmp/SKILL.md")" = "---"
printf '%s\n' "$huella" > "$remote_tmp/.agent-version"

if [ ! -d "$remote_release" ]; then
  mv "$remote_tmp" "$remote_release"
else
  rm -rf "$remote_tmp"
fi

ln -sfn ".versiones/$huella" "$remote_agent/actual.nuevo"
mv -Tf "$remote_agent/actual.nuevo" "$remote_agent/actual"

test "$(cat "$remote_agent/actual/.agent-version")" = "$huella"
REMOTE_SCRIPT

echo "✓ Agente '$ROLE' actualizado y activado ($huella)."
