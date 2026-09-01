#!/usr/bin/env bash
# Instala en una VM el actualizador Git y su ciclo periódico de comprobación.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
ACTUALIZADOR_LOCAL="$ROOT/tools/remotos/actualizar_agente_git.sh"
CICLO_LOCAL="$ROOT/tools/remotos/ciclo_actualizacion_git.sh"
VM_PROFILE="${1:-}"

if [ -z "$VM_PROFILE" ]; then
  echo "Uso: ./tools/sincronizacion/instalar_actualizacion_git.sh <perfil-vm>" >&2
  exit 1
fi

if [[ ! "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: el perfil de VM solo puede contener letras minúsculas, números y guiones." >&2
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

ip="$(GET_VM_FIELD "$VM_PROFILE" "ip")"
user="$(GET_VM_FIELD "$VM_PROFILE" "user")"
role="$(GET_VM_FIELD "$VM_PROFILE" "stack")"
remote_agent="$(GET_VM_FIELD "$VM_PROFILE" "remote_agent")"
git_url="$(GET_VM_FIELD "$VM_PROFILE" "git_url")"
git_branch="$(GET_VM_FIELD "$VM_PROFILE" "git_branch")"
git_agent_path="$(GET_VM_FIELD "$VM_PROFILE" "git_agent_path")"
poll_seconds="$(GET_VM_FIELD "$VM_PROFILE" "agent_poll_seconds")"

if [ -z "$ip" ] || [ -z "$user" ] || [ -z "$role" ] || [ -z "$remote_agent" ] || [ -z "$git_url" ] || [ -z "$git_branch" ] || [ -z "$git_agent_path" ] || [ -z "$poll_seconds" ]; then
  echo "Error: configuración Git incompleta para el perfil '$VM_PROFILE' en vms.json." >&2
  exit 1
fi
if [ "$role" != "backend" ] && [ "$role" != "frontend" ]; then
  echo "Error: stack no soportado para el perfil '$VM_PROFILE'." >&2
  exit 1
fi

case "$poll_seconds" in
  10|15|20|30|60) ;;
  *)
    echo "Error: agent_poll_seconds debe ser 10, 15, 20, 30 o 60." >&2
    exit 1
    ;;
esac

if [[ ! "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: remote_agent debe permanecer dentro de /home/<usuario>/agentes/." >&2
  exit 1
fi

if [[ ! "$git_url" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || [[ ! "$git_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! "$git_agent_path" =~ ^skills/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: git_url, git_branch o git_agent_path no son válidos." >&2
  exit 1
fi

if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Error: usuario o dirección SSH no válidos para el perfil '$VM_PROFILE'." >&2
  exit 1
fi

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

echo "🔧 Instalando actualización Git automática para '$VM_PROFILE' en $user@$ip..."

ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "mkdir -p '$remote_agent' && install -m 0755 /dev/stdin '$remote_agent/actualizar_desde_git.sh.nuevo' && mv -f '$remote_agent/actualizar_desde_git.sh.nuevo' '$remote_agent/actualizar_desde_git.sh'" \
  < "$ACTUALIZADOR_LOCAL"

ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "install -m 0755 /dev/stdin '$remote_agent/ciclo_actualizacion_git.sh.nuevo' && mv -f '$remote_agent/ciclo_actualizacion_git.sh.nuevo' '$remote_agent/ciclo_actualizacion_git.sh'" \
  < "$CICLO_LOCAL"

printf '%s\n%s\n%s\n%s\n%s\n' "$git_url" "$git_branch" "$role" "$git_agent_path" "$poll_seconds" \
  | ssh "${SSH_OPTS[@]}" "$user@$ip" \
      "install -m 0600 /dev/stdin '$remote_agent/git-agent.conf.nuevo' && mv -f '$remote_agent/git-agent.conf.nuevo' '$remote_agent/git-agent.conf'"

ssh "${SSH_OPTS[@]}" "$user@$ip" bash -s -- "$VM_PROFILE" "$remote_agent" <<'REMOTE_INSTALL'
set -euo pipefail

profile="$1"
remote_agent="$2"
marker="# prueba-agentes-$profile"
cron_line="* * * * * AGENTE_SILENCIOSO=1 $remote_agent/ciclo_actualizacion_git.sh >> $remote_agent/actualizaciones.log 2>&1 $marker"

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

echo "✓ Actualización automática instalada para '$VM_PROFILE' como '$role' (cada $poll_seconds segundos)."
