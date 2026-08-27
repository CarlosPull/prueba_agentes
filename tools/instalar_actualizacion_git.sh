#!/usr/bin/env bash
# Instala en una VM el actualizador Git y un cron de comprobación cada minuto.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"
ACTUALIZADOR_LOCAL="$ROOT/tools/remotos/actualizar_agente_git.sh"
ROLE="${1:-}"

if [ -z "$ROLE" ]; then
  echo "Uso: ./tools/instalar_actualizacion_git.sh <rol>" >&2
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
git_url="$(GET_VM_FIELD "$ROLE" "git_url")"
git_branch="$(GET_VM_FIELD "$ROLE" "git_branch")"
git_agent_path="$(GET_VM_FIELD "$ROLE" "git_agent_path")"

if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$remote_agent" ] || [ -z "$git_url" ] || [ -z "$git_branch" ] || [ -z "$git_agent_path" ]; then
  echo "Error: configuración Git incompleta para el rol '$ROLE' en vms.json." >&2
  exit 1
fi

if [[ ! "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: remote_agent debe permanecer dentro de /home/<usuario>/agentes/." >&2
  exit 1
fi

if [[ ! "$git_url" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || [[ ! "$git_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! "$git_agent_path" =~ ^skills/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: git_url, git_branch o git_agent_path no son válidos." >&2
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

echo "🔧 Instalando actualización Git automática para '$ROLE' en $user@$ip..."

ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "mkdir -p '$remote_agent' && install -m 0755 /dev/stdin '$remote_agent/actualizar_desde_git.sh'" \
  < "$ACTUALIZADOR_LOCAL"

printf '%s\n%s\n%s\n%s\n' "$git_url" "$git_branch" "$ROLE" "$git_agent_path" \
  | ssh "${SSH_OPTS[@]}" "$user@$ip" \
      "install -m 0600 /dev/stdin '$remote_agent/git-agent.conf'"

ssh "${SSH_OPTS[@]}" "$user@$ip" bash -s -- "$ROLE" "$remote_agent" <<'REMOTE_INSTALL'
set -euo pipefail

role="$1"
remote_agent="$2"
marker="# prueba-agentes-$role"
cron_line="* * * * * AGENTE_SILENCIOSO=1 $remote_agent/actualizar_desde_git.sh >> $remote_agent/actualizaciones.log 2>&1 $marker"

command -v crontab >/dev/null 2>&1
systemctl is-active --quiet cron

cron_actual="$(crontab -l 2>/dev/null || true)"
cron_filtrado="$(printf '%s\n' "$cron_actual" | grep -vF "$marker" || true)"
{
  [ -n "$cron_filtrado" ] && printf '%s\n' "$cron_filtrado"
  printf '%s\n' "$cron_line"
} | crontab -

"$remote_agent/actualizar_desde_git.sh"
crontab -l | grep -F "$marker" >/dev/null
REMOTE_INSTALL

echo "✓ Actualización automática instalada para '$ROLE' (comprobación cada minuto)."
