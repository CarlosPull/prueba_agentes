#!/usr/bin/env bash
# Registra un repositorio/módulo adicional en una VM y crea su memoria local.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$ROOT/vms.json}"
PROFILE="${1:-}"
REPOSITORY="${2:-}"
MODULE="${3:-}"
KIND="${4:-}"
LOCAL_PATH="${5:-}"
REMOTE_PATH="${6:-}"
ALIASES_CSV="${7:-$REPOSITORY,$MODULE}"
MODE="${8:-}"

if [ -z "$PROFILE" ] || [ -z "$REPOSITORY" ] || [ -z "$MODULE" ] || [ -z "$KIND" ] || [ -z "$LOCAL_PATH" ] || [ -z "$REMOTE_PATH" ]; then
  echo "Uso: ./tools/agregar_repositorio_vm.sh <perfil> <repo-id> <modulo> <module|core|frontend> <ruta-local> <ruta-remota> [aliases,separados,por,coma] [--solo-configurar]" >&2
  exit 1
fi
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$REPOSITORY" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$MODULE" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "Error: perfil, repositorio o módulo no válido." >&2; exit 1;
}
case "$KIND" in module|core|frontend) ;; *) echo "Error: tipo inválido; usa module, core o frontend." >&2; exit 1 ;; esac
[ -d "$LOCAL_PATH" ] || { echo "Error: no existe el proyecto local '$LOCAL_PATH'." >&2; exit 1; }
[ -z "$MODE" ] || [ "$MODE" = "--solo-configurar" ] || { echo "Error: opción no reconocida '$MODE'." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }

user="$(jq -er --arg profile "$PROFILE" '.[$profile].user' "$VMS_CONF")" || { echo "Error: perfil '$PROFILE' inexistente." >&2; exit 1; }
ip="$(jq -er --arg profile "$PROFILE" '.[$profile].ip' "$VMS_CONF")"
stack="$(jq -er --arg profile "$PROFILE" '.[$profile].stack' "$VMS_CONF")"
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "Error: usuario o IP inseguros en '$PROFILE'." >&2; exit 1; }
[[ "$REMOTE_PATH" =~ ^/home/$user/[A-Za-z0-9._/-]+$ ]] || { echo "Error: la ruta remota debe permanecer dentro de /home/$user/." >&2; exit 1; }
if [ "$stack" = "frontend" ] && [ "$KIND" != "frontend" ]; then
  echo "Error: una VM frontend sólo admite repositorios de tipo frontend." >&2; exit 1
fi
jq -e --arg profile "$PROFILE" --arg repository "$REPOSITORY" \
  'all((.[$profile].repositories // [])[]; .id != $repository)' "$VMS_CONF" >/dev/null || {
    echo "Error: '$REPOSITORY' ya está registrado en '$PROFILE'." >&2; exit 1;
  }

memory_path="/home/$user/.local/share/prueba-agentes/business/$REPOSITORY.md"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
if [ "$MODE" != "--solo-configurar" ]; then
  command -v rsync >/dev/null 2>&1 || { echo "Error: rsync es obligatorio." >&2; exit 1; }
  echo "📤 Copiando '$REPOSITORY' a $user@$ip:$REMOTE_PATH..."
  ssh "${SSH_OPTS[@]}" "$user@$ip" "install -d -m 0750 '$REMOTE_PATH'"
  rsync -az --delete --exclude='.git/' -e "ssh ${SSH_OPTS[*]}" "$LOCAL_PATH/" "$user@$ip:$REMOTE_PATH/"
fi

memory_parent="${memory_path%/*}"
ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "install -d -m 0700 '$memory_parent'; if [ ! -e '$memory_path' ]; then printf '# Memoria de negocio: %s (%s)\n\nDescribe aquí únicamente las reglas privadas de este módulo.\n' '$MODULE' '$REPOSITORY' > '$memory_path'; fi; chmod 0600 '$memory_path'"

aliases_json="$(printf '%s' "$ALIASES_CSV" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
config_tmp="$(mktemp "$VMS_CONF.repositorio.XXXXXX")"
trap 'rm -f "$config_tmp"' EXIT INT TERM
jq --arg profile "$PROFILE" --arg id "$REPOSITORY" --arg module "$MODULE" --arg kind "$KIND" \
  --arg path "$REMOTE_PATH" --arg business_memory "$memory_path" --argjson aliases "$aliases_json" '
  .[$profile].repositories = ((.[$profile].repositories // []) + [{
    id:$id,module:$module,kind:$kind,path:$path,business_memory:$business_memory,aliases:$aliases
  }])
' "$VMS_CONF" > "$config_tmp"
mv "$config_tmp" "$VMS_CONF"
trap - EXIT INT TERM
echo "✓ Repositorio '$REPOSITORY' registrado en '$PROFILE'; el analista ya puede seleccionarlo."
echo "  Memoria de negocio local: $memory_path"
