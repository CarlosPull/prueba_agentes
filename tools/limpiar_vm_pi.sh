#!/usr/bin/env bash
# Elimina artefactos administrados por este orquestador, conservando SO y login Pi.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PROFILE="${1:-}"
CONFIRMATION="${2:-}"
[ -n "$PROFILE" ] || { echo "Uso: ./tools/limpiar_vm_pi.sh <perfil> --confirmar-limpieza" >&2; exit 1; }
[ "$CONFIRMATION" = "--confirmar-limpieza" ] || { echo "Error: falta --confirmar-limpieza." >&2; exit 1; }
[[ "$PROFILE" =~ ^[a-z0-9-]+$ ]] || { echo "Error: perfil inválido." >&2; exit 1; }

ip="$(jq -er --arg profile "$PROFILE" '.[$profile].ip' "$VMS_CONF")" || { echo "Error: perfil inexistente." >&2; exit 1; }
user="$(jq -er --arg profile "$PROFILE" '.[$profile].user' "$VMS_CONF")"
remote_agent="$(jq -er --arg profile "$PROFILE" '.[$profile].remote_agent' "$VMS_CONF")"
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "Error: destino SSH inseguro." >&2; exit 1; }
[[ "$remote_agent" =~ ^/home/$user/agentes/[A-Za-z0-9._/-]+$ ]] || { echo "Error: ruta de agente insegura." >&2; exit 1; }

paths=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [[ "$path" =~ ^/home/$user/[A-Za-z0-9._/-]+$ ]] || { echo "Error: ruta administrada insegura: $path" >&2; exit 1; }
  paths+=("$path")
done < <(jq -r --arg profile "$PROFILE" '([.[$profile].workspace] + [(.[$profile].repositories // [])[].path]) | unique[]' "$VMS_CONF")
[ "${#paths[@]}" -gt 0 ] || { echo "Error: el perfil no declara workspaces." >&2; exit 1; }

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
echo "🧹 Limpiando artefactos de '$PROFILE' en $user@$ip..."
ssh "${SSH_OPTS[@]}" "$user@$ip" bash -s -- "$PROFILE" "$remote_agent" "${paths[@]}" <<'REMOTE_CLEAN'
set -euo pipefail
profile="$1"
remote_agent="$2"
shift 2
: "$profile"
for target in "$@"; do
  case "$target" in "$HOME"/*) ;; *) echo "Ruta rechazada: $target" >&2; exit 1 ;; esac
  [ "$target" != "$HOME" ] || { echo "No se permite borrar HOME." >&2; exit 1; }
  rm -rf -- "$target"
done
rm -rf -- "$remote_agent" "$HOME/.local/lib/prueba-agentes" "$HOME/.local/share/prueba-agentes/business"
rm -f -- "$HOME/.local/bin/pi-harness"
cron_actual="$(crontab -l 2>/dev/null || true)"
printf '%s\n' "$cron_actual" | grep -vF '# prueba-agentes-' | crontab - || true
REMOTE_CLEAN
echo "✓ Se eliminaron proyectos, agente, pi-harness, memorias locales y cron de '$PROFILE'."
echo "  Se conservaron Ubuntu, PHP, Node, Pi y la autenticación de Pi."

config_tmp="$(mktemp "$VMS_CONF.limpieza.XXXXXX")"
trap 'rm -f "$config_tmp"' EXIT INT TERM
jq --arg profile "$PROFILE" '.[$profile].dispatch_enabled = false' "$VMS_CONF" > "$config_tmp"
chmod --reference="$VMS_CONF" "$config_tmp" 2>/dev/null || chmod 0644 "$config_tmp"
mv "$config_tmp" "$VMS_CONF"
trap - EXIT INT TERM
echo "  Perfil deshabilitado en vms.json hasta su siguiente provisionamiento."
