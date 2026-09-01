#!/usr/bin/env bash
# Copia y activa en una VM un agente cuyo perfil usa source_mode=local.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
VM_PROFILE="${1:-}"
SILENCIOSO="${2:-}"

if [ -z "$VM_PROFILE" ]; then
  echo "Uso: ./tools/sincronizacion/sincronizar_agente_local.sh <perfil-vm> [--silencioso]" >&2
  exit 1
fi
if [[ ! "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: perfil de VM no válido." >&2
  exit 1
fi

GET_VM_FIELD() {
  local field="$1"
  jq -r --arg profile "$VM_PROFILE" --arg field "$field" \
    'if (.[$profile] | type) == "object" and (.[$profile] | has($field)) then .[$profile][$field] else empty end' \
    "$VMS_CONF" 2>/dev/null || true
}

source_mode="$(GET_VM_FIELD source_mode)"
ip="$(GET_VM_FIELD ip)"
user="$(GET_VM_FIELD user)"
stack="$(GET_VM_FIELD stack)"
remote_agent="$(GET_VM_FIELD remote_agent)"
local_agent_rel="$(GET_VM_FIELD local_agent)"
local_agent="$ROOT/$local_agent_rel"

if [ "$source_mode" != "local" ]; then
  echo "Error: '$VM_PROFILE' no utiliza source_mode=local." >&2
  exit 1
fi
if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$stack" ] || [ -z "$remote_agent" ] || [ ! -s "$local_agent/SKILL.md" ]; then
  echo "Error: configuración local incompleta para '$VM_PROFILE'." >&2
  exit 1
fi
if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Error: usuario o IP no válidos para '$VM_PROFILE'." >&2
  exit 1
fi
if [[ ! "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: ruta remota del agente no válida." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq no está instalado." >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "Error: rsync no está instalado." >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "Error: shasum no está instalado." >&2; exit 1; }

hash="$({
  find "$local_agent" -type f ! -name '.DS_Store' -print | LC_ALL=C sort | while IFS= read -r archivo; do
    relativa="${archivo#"$local_agent/"}"
    printf '%s  ' "$relativa"
    shasum -a 256 "$archivo"
  done
} | shasum -a 256 | awk '{print $1}')"
version="local-$hash"
target="$user@$ip"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

version_actual="$(ssh "${SSH_OPTS[@]}" "$target" "cat '$remote_agent/actual/.agent-version' 2>/dev/null || true")"
if [ "$version_actual" = "$version" ]; then
  [ "$SILENCIOSO" = "--silencioso" ] || echo "✓ Agente '$VM_PROFILE' ya está actualizado desde la Mac ($version)."
  exit 0
fi

tmp="$remote_agent/.versiones/.$version.tmp.$$"
destino="$remote_agent/.versiones/$version"
ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$tmp'"
rsync -az --exclude='.git/' --exclude='.DS_Store' "$local_agent/" "$target:$tmp/"

ssh "${SSH_OPTS[@]}" "$target" bash -s -- "$remote_agent" "$tmp" "$destino" "$version" <<'REMOTE_ACTIVAR'
set -euo pipefail
remote_agent="$1"
tmp="$2"
destino="$3"
version="$4"

test -s "$tmp/SKILL.md"
test "$(sed -n '1p' "$tmp/SKILL.md")" = "---"
printf '%s\n' "$version" > "$tmp/.agent-version"
printf '%s\n' local > "$tmp/.git-commit"

exec 9>"$remote_agent/.actualizacion.lock"
flock -x 9
if [ ! -d "$destino" ]; then
  mv "$tmp" "$destino"
else
  rm -rf "$tmp"
fi
ln -sfn ".versiones/$version" "$remote_agent/actual.nuevo"
mv -Tf "$remote_agent/actual.nuevo" "$remote_agent/actual"
test "$(cat "$remote_agent/actual/.agent-version")" = "$version"
REMOTE_ACTIVAR

echo "✓ Agente '$VM_PROFILE' copiado desde la Mac y activado ($version)."
