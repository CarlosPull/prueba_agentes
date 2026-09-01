#!/usr/bin/env bash
# Crea o reemplaza de forma no interactiva un perfil backend desde un repo local.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PROFILE="${1:-}"
IP="${2:-}"
USER_VM="${3:-}"
LOCAL_PATH="${4:-}"
KIND="${5:-}"
REPOSITORY="${6:-}"
MODULE="${7:-}"
ALIASES_CSV="${8:-}"
REMOTE_PATH="${9:-}"

if [ -z "$PROFILE" ] || [ -z "$IP" ] || [ -z "$USER_VM" ] || [ -z "$LOCAL_PATH" ] || [ -z "$KIND" ] || [ -z "$REPOSITORY" ] || [ -z "$MODULE" ]; then
  echo "Uso: ./tools/vms/configurar_perfil_backend_local.sh <perfil> <ip> <usuario> <repo-local> <core|module> <repo-id> <modulo> [aliases-csv] [workspace-remoto]" >&2
  exit 1
fi
[[ "$PROFILE" =~ ^[a-z0-9-]+$ ]] && [[ "$IP" =~ ^[A-Za-z0-9.:-]+$ ]] && [[ "$USER_VM" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Error: perfil, IP o usuario no válidos." >&2; exit 1; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$MODULE" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Error: repo-id o módulo no válido." >&2; exit 1; }
[ "$KIND" = "core" ] || [ "$KIND" = "module" ] || { echo "Error: kind debe ser core o module." >&2; exit 1; }
[ -d "$LOCAL_PATH" ] && [ -s "$LOCAL_PATH/composer.json" ] || { echo "Error: '$LOCAL_PATH' no es un repositorio Composer." >&2; exit 1; }
[ "$KIND" != "core" ] || [ -s "$LOCAL_PATH/artisan" ] || { echo "Error: el core no contiene artisan." >&2; exit 1; }

REMOTE_PATH="${REMOTE_PATH:-/home/$USER_VM/$REPOSITORY}"
[[ "$REMOTE_PATH" =~ ^/home/$USER_VM/[A-Za-z0-9._/-]+$ ]] || { echo "Error: workspace remoto inseguro." >&2; exit 1; }
ALIASES_CSV="${ALIASES_CSV:-$REPOSITORY,$MODULE}"
aliases_json="$(printf '%s' "$ALIASES_CSV" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
agent_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
[[ "$agent_url" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || agent_url="https://github.com/CarlosPull/prueba_agentes.git"
agent_branch="$(git -C "$ROOT" branch --show-current)"
[[ "$agent_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Error: la rama actual del orquestador no es válida." >&2; exit 1; }

config_tmp="$(mktemp "$VMS_CONF.backend.XXXXXX")"
trap 'rm -f "$config_tmp"' EXIT INT TERM
jq --arg profile "$PROFILE" --arg ip "$IP" --arg user "$USER_VM" --arg workspace "$REMOTE_PATH" \
  --arg local_path "$LOCAL_PATH" --arg kind "$KIND" --arg repository "$REPOSITORY" --arg module "$MODULE" \
  --argjson aliases "$aliases_json" --arg agent_url "$agent_url" --arg agent_branch "$agent_branch" '
  .[$profile] = {
    ip:$ip,user:$user,workspace:$workspace,stack:"backend",
    repositories:[{
      id:$repository,module:$module,kind:$kind,path:$workspace,
      business_memory:("/home/" + $user + "/.local/share/prueba-agentes/business/" + $repository + ".md"),
      aliases:$aliases
    }],
    engine:"pi",dispatch_enabled:false,
    pi_harness:("/home/" + $user + "/.local/bin/pi-harness"),
    pi_provider:"openai-codex",pi_model:"gpt-5.4-mini",
    memory:{enabled:false,gateway_url:"",core_id:"",tenant_id:"",read_business:false,read_company:false,tls_key:"",tls_cert:"",tls_ca:""},
    source_mode:"local",project_local_path:$local_path,
    agent_update_mode:"git",node_version:"24.19.0",pi_version:"latest",
    php_version:"8.4",php_min_version:"8.4.1",
    install_dependencies:($kind == "core"),
    local_agent:"skills/dev-back",remote_agent:("/home/" + $user + "/agentes/backend"),
    git_url:$agent_url,git_branch:$agent_branch,git_agent_path:"skills/dev-back",agent_poll_seconds:30
  }
' "$VMS_CONF" > "$config_tmp"
chmod --reference="$VMS_CONF" "$config_tmp" 2>/dev/null || chmod 0644 "$config_tmp"
mv "$config_tmp" "$VMS_CONF"
trap - EXIT INT TERM
echo "✓ Perfil '$PROFILE' configurado: $KIND $REPOSITORY → $USER_VM@$IP:$REMOTE_PATH"
echo "  Ejecuta: ./tools/vms/provisionar_vm_pi.sh $PROFILE --con-sudo-interactivo"
