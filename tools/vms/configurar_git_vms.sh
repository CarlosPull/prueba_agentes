#!/usr/bin/env bash
# Herramienta para automatizar la vinculación de repositorios Git reales y credenciales en las VMs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio." >&2
  exit 1
}

GIT_NAME="${PRUEBA_AGENTES_GIT_NAME:-$(git config --global user.name 2>/dev/null || echo "Desarrollador Agentes")}"
GIT_EMAIL="${PRUEBA_AGENTES_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo "desarrollador@ejemplo.invalid")}"
RESET_GIT=0
TARGET_PROFILE=""


USO() {
  echo "Uso: ./tools/vms/configurar_git_vms.sh [--reset] [--name \"Nombre\"] [--email \"email@ejemplo.com\"] [perfil-vm]"
  echo "Ejemplo: ./tools/vms/configurar_git_vms.sh --reset --name \"Carlos\" --email \"carlos@ejemplo.com\""
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reset|--limpiar) RESET_GIT=1; shift ;;
    --name) [ "$#" -ge 2 ] || exit 1; GIT_NAME="$2"; shift 2 ;;
    --email) [ "$#" -ge 2 ] || exit 1; GIT_EMAIL="$2"; shift 2 ;;
    --help|-h) USO; exit 0 ;;
    *)
      if [ -z "$TARGET_PROFILE" ]; then TARGET_PROFILE="$1"; else echo "Error: opción no reconocida '$1'" >&2; exit 1; fi
      shift ;;
  esac
done


KEY_FILE="$HOME/.ssh/id_ed25519"
PUB_KEY_FILE="$KEY_FILE.pub"

[ -f "$KEY_FILE" ] && [ -f "$PUB_KEY_FILE" ] || {
  echo "Error: no se encontró la llave SSH local en $KEY_FILE. Ejecuta ssh-keygen primero." >&2
  exit 1
}

perfiles=()
if [ -n "$TARGET_PROFILE" ]; then
  jq -e --arg profile "$TARGET_PROFILE" '.[$profile]' "$VMS_CONF" >/dev/null || { echo "Error: perfil '$TARGET_PROFILE' no existe en $VMS_CONF" >&2; exit 1; }
  perfiles+=("$TARGET_PROFILE")
else
  while IFS= read -r profile; do
    [ -n "$profile" ] && perfiles+=("$profile")
  done < <(jq -r 'to_entries[] | select(.value.dispatch_enabled == true or .value.engine == "pi") | .key' "$VMS_CONF")
fi

echo "🚀 Configurando repositorio Git e identidad en ${#perfiles[@]} VM(s)..."
echo "  - Nombre Git: $GIT_NAME"
echo "  - Email Git:  $GIT_EMAIL"
echo "------------------------------------------------------------"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
pub_key="$(cat "$PUB_KEY_FILE")"
priv_key="$(cat "$KEY_FILE")"

for profile in "${perfiles[@]}"; do
  ip="$(jq -r --arg p "$profile" '.[$p].ip // ""' "$VMS_CONF")"
  user="$(jq -r --arg p "$profile" '.[$p].user // ""' "$VMS_CONF")"
  workspace="$(jq -r --arg p "$profile" '.[$p].workspace // ""' "$VMS_CONF")"
  local_path="$(jq -r --arg p "$profile" '.[$p].project_local_path // ""' "$VMS_CONF")"

  if [ -z "$ip" ] || [ -z "$user" ]; then
    echo "⚠️ Omitiendo '$profile': IP o usuario no definidos."
    continue
  fi

  # Detectar la URL Git real y la rama activa del proyecto local en la Mac
  real_git_url=""
  real_git_branch="main"

  if [ -n "$local_path" ] && [ -d "$local_path/.git" ]; then
    real_git_url="$(git -C "$local_path" remote get-url origin 2>/dev/null || true)"
    real_git_branch="$(git -C "$local_path" branch --show-current 2>/dev/null || echo "main")"
  fi

  if [ -z "$real_git_url" ]; then
    real_git_url="$(jq -r --arg p "$profile" '.[$p].project_git_url // .[$p].repositories[0].git_url // ""' "$VMS_CONF")"
  fi

  if [ -z "$real_git_url" ]; then
    echo "⚠️ No se pudo determinar el repositorio Git oficial para '$profile' (local: $local_path)."
    continue
  fi

  if [[ "$real_git_url" =~ ^https://github\.com/([^/]+)/([^/]+)(\.git)?$ ]]; then
    real_git_url="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}.git"
  fi

  echo "🌐 Configurando VM '$profile' ($user@$ip)..."
  echo "  - Proyecto: $workspace"
  echo "  - Remoto oficial: $real_git_url"

  echo "  - Rama por defecto: $real_git_branch"

  ssh "${SSH_OPTS[@]}" "$user@$ip" "
    set -eu
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    printf '%s\n' '$pub_key' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    # Llaves SSH salientes hacia GitHub/remoto
    if [ ! -f ~/.ssh/id_ed25519 ]; then
      printf '%s\n' '$priv_key' > ~/.ssh/id_ed25519
      printf '%s\n' '$pub_key' > ~/.ssh/id_ed25519.pub
      chmod 600 ~/.ssh/id_ed25519
      chmod 644 ~/.ssh/id_ed25519.pub
    fi

    # Configuración de usuario global en Git
    git config --global user.name '$GIT_NAME'
    git config --global user.email '$GIT_EMAIL'

    # SSH config para GitHub sin confirmación interactiva
    if ! grep -q 'Host github.com' ~/.ssh/config 2>/dev/null; then
      printf 'Host github.com\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' >> ~/.ssh/config
      chmod 600 ~/.ssh/config
    fi

    # Inicialización/vinculación del proyecto real
    if [ -d '$workspace' ]; then
      cd '$workspace'
      if [ '$RESET_GIT' -eq 1 ]; then
        rm -rf .git
      fi
      if [ ! -d .git ]; then
        git init -q
      fi


      git remote add origin '$real_git_url' 2>/dev/null || git remote set-url origin '$real_git_url'
      git fetch origin 2>/dev/null || true

      # Crear/vincular la rama local con la rama remota oficial
      if git show-ref --verify --quiet 'refs/remotes/origin/$real_git_branch'; then
        git checkout -B '$real_git_branch' 'origin/$real_git_branch' 2>/dev/null || git checkout -B '$real_git_branch' 2>/dev/null || true
      else
        git checkout -B '$real_git_branch' 2>/dev/null || true
      fi
    fi
  "

  echo "  ✓ '$profile' vinculado correctamente a $real_git_url (rama: $real_git_branch)."
done

echo "------------------------------------------------------------"
echo "✅ Todos los repositorios oficiales quedaron vinculados en las VMs."
