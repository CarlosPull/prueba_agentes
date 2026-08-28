#!/usr/bin/env bash
# Provisiona una VM completa por rol usando vms.json como fuente de verdad.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="$ROOT/vms.json"
BOOTSTRAP_LOCAL="$ROOT/tools/remotos/provisionar_vm.sh"
PAQUETES_BACKEND_LOCAL="$ROOT/tools/remotos/instalar_paquetes_backend.sh"
VM_PROFILE="${1:-}"
OPCION="${2:-}"

if [ -z "$VM_PROFILE" ]; then
  echo "Uso: ./tools/provisionar_vm.sh <perfil-vm> [--con-sudo-interactivo|--solo-verificar]" >&2
  exit 1
fi
if [[ ! "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: el perfil de VM solo puede contener letras minúsculas, números y guiones." >&2
  exit 1
fi
if [ -n "$OPCION" ] && [ "$OPCION" != "--con-sudo-interactivo" ] && [ "$OPCION" != "--solo-verificar" ]; then
  echo "Error: opción no reconocida: '$OPCION'." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

GET_VM_FIELD() {
  local field="$1"
  jq -r --arg profile "$VM_PROFILE" --arg field "$field" \
    'if (.[$profile] | type) == "object" and (.[$profile] | has($field)) then .[$profile][$field] else empty end' \
    "$VMS_CONF" 2>/dev/null || true
}

ip="$(GET_VM_FIELD ip)"
user="$(GET_VM_FIELD user)"
workspace="$(GET_VM_FIELD workspace)"
stack="$(GET_VM_FIELD stack)"
source_mode="$(GET_VM_FIELD source_mode)"
[ -n "$source_mode" ] || source_mode="git"
agent_update_mode="$(GET_VM_FIELD agent_update_mode)"
[ -n "$agent_update_mode" ] || agent_update_mode="git"
project_local_path="$(GET_VM_FIELD project_local_path)"
runner_local_path="$(GET_VM_FIELD agent_runner_local_path)"
project_git_url="$(GET_VM_FIELD project_git_url)"
project_git_branch="$(GET_VM_FIELD project_git_branch)"
runner_bin="$(GET_VM_FIELD agent_runner)"
runner_git_url="$(GET_VM_FIELD agent_runner_git_url)"
runner_git_branch="$(GET_VM_FIELD agent_runner_git_branch)"
node_version="$(GET_VM_FIELD node_version)"
opencode_version="$(GET_VM_FIELD opencode_version)"
php_version="$(GET_VM_FIELD php_version)"
php_min_version="$(GET_VM_FIELD php_min_version)"
install_dependencies="$(GET_VM_FIELD install_dependencies)"
remote_agent="$(GET_VM_FIELD remote_agent)"
agent_git_url="$(GET_VM_FIELD git_url)"
agent_git_branch="$(GET_VM_FIELD git_branch)"
agent_git_path="$(GET_VM_FIELD git_agent_path)"
agent_poll_seconds="$(GET_VM_FIELD agent_poll_seconds)"

for valor in "$ip" "$user" "$workspace" "$stack" "$runner_bin" "$node_version" "$opencode_version" "$install_dependencies" "$remote_agent"; do
  if [ -z "$valor" ]; then
    echo "Error: configuración de provisionamiento incompleta para '$VM_PROFILE' en vms.json." >&2
    exit 1
  fi
done
if [ "$source_mode" != "git" ] && [ "$source_mode" != "local" ]; then
  echo "Error: source_mode debe ser 'git' o 'local' en '$VM_PROFILE'." >&2
  exit 1
fi
if [ "$agent_update_mode" != "git" ] && [ "$agent_update_mode" != "local" ]; then
  echo "Error: agent_update_mode debe ser 'git' o 'local' en '$VM_PROFILE'." >&2
  exit 1
fi
if [ "$source_mode" = "git" ]; then
  for valor in "$project_git_url" "$project_git_branch" "$runner_git_url" "$runner_git_branch"; do
    [ -n "$valor" ] || { echo "Error: configuración Git de fuentes incompleta para '$VM_PROFILE'." >&2; exit 1; }
  done
else
  for ruta in "$project_local_path" "$runner_local_path" "$ROOT/$(GET_VM_FIELD local_agent)"; do
    [ -d "$ruta" ] || { echo "Error: no existe la fuente local '$ruta'." >&2; exit 1; }
  done
  if [ "$stack" = "backend" ]; then
    [ -s "$project_local_path/composer.json" ] && [ -s "$project_local_path/artisan" ] || {
      echo "Error: '$project_local_path' no contiene un proyecto Laravel válido." >&2
      exit 1
    }
  else
    [ -s "$project_local_path/package.json" ] || {
      echo "Error: '$project_local_path' no contiene un proyecto frontend válido." >&2
      exit 1
    }
  fi
  [ -s "$runner_local_path/pyproject.toml" ] || {
    echo "Error: '$runner_local_path' no contiene un agent-runner válido." >&2
    exit 1
  }
  [ -s "$ROOT/$(GET_VM_FIELD local_agent)/SKILL.md" ] || {
    echo "Error: el agente local de '$VM_PROFILE' no contiene SKILL.md." >&2
    exit 1
  }
  command -v rsync >/dev/null 2>&1 || { echo "Error: rsync no está instalado en la Mac." >&2; exit 1; }
fi
if [ "$agent_update_mode" = "git" ]; then
  for valor in "$agent_git_url" "$agent_git_branch" "$agent_git_path" "$agent_poll_seconds"; do
    [ -n "$valor" ] || { echo "Error: configuración Git del agente incompleta para '$VM_PROFILE'." >&2; exit 1; }
  done
fi

if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Error: usuario o dirección SSH no válidos para '$VM_PROFILE'." >&2
  exit 1
fi
if [ "$stack" != "backend" ] && [ "$stack" != "frontend" ]; then
  echo "Error: el stack '$stack' del perfil '$VM_PROFILE' no está soportado." >&2
  exit 1
fi
if [ "$stack" = "backend" ]; then
  if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || [[ ! "$php_min_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: php_version o php_min_version no son válidos para '$VM_PROFILE'." >&2
    exit 1
  fi
fi
if [ ! -s "$BOOTSTRAP_LOCAL" ]; then
  echo "Error: no existe el bootstrap remoto '$BOOTSTRAP_LOCAL'." >&2
  exit 1
fi
if [ "$stack" = "backend" ] && [ ! -s "$PAQUETES_BACKEND_LOCAL" ]; then
  echo "Error: no existe el instalador backend '$PAQUETES_BACKEND_LOCAL'." >&2
  exit 1
fi

target="$user@$ip"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
fi

if ! ssh "${SSH_OPTS[@]}" "$target" "echo OK" >/dev/null 2>&1; then
  echo "🔑 No existe acceso SSH no interactivo; iniciando configuración..."
  "$ROOT/tools/configurar_ssh_vm.sh" "$target"
fi

if [ "$OPCION" = "--con-sudo-interactivo" ]; then
  paquetes=(git curl ca-certificates cron jq tar rsync util-linux bubblewrap python3 python3-pip build-essential locales software-properties-common)
  if [ "$stack" = "backend" ]; then
    remote_package_installer="/home/$user/.local/lib/prueba-agentes/instalar_paquetes_backend.sh"
    ssh "${SSH_OPTS[@]}" "$target" \
      "mkdir -p '/home/$user/.local/lib/prueba-agentes' && install -m 0755 /dev/stdin '$remote_package_installer.nuevo' && mv -f '$remote_package_installer.nuevo' '$remote_package_installer'" \
      < "$PAQUETES_BACKEND_LOCAL"
    echo "📦 Instalando paquetes del sistema y PHP $php_version en '$target'..."
    ssh -tt "${SSH_OPTS[@]}" "$target" \
      "'$remote_package_installer' '$php_version' '$php_min_version' ${paquetes[*]}"
  else
    echo "📦 Instalando paquetes del sistema en '$target'..."
    ssh -tt "${SSH_OPTS[@]}" "$target" \
      "export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo apt-get update && sudo apt-get install -y ${paquetes[*]} && sudo systemctl enable --now cron"
  fi
fi

remote_bootstrap="/home/$user/.local/lib/prueba-agentes/provisionar_vm.sh"
ssh "${SSH_OPTS[@]}" "$target" \
  "mkdir -p '/home/$user/.local/lib/prueba-agentes' && install -m 0755 /dev/stdin '$remote_bootstrap.nuevo' && mv -f '$remote_bootstrap.nuevo' '$remote_bootstrap'" \
  < "$BOOTSTRAP_LOCAL"

modo="provisionar"
[ "$OPCION" = "--solo-verificar" ] && modo="verificar"

COPIAR_FUENTES_LOCALES() {
  local local_agent_path
  local version_local
  local version_dir
  local_agent_path="$ROOT/$(GET_VM_FIELD local_agent)"
  version_local="local-$(date +%Y%m%d%H%M%S)"
  version_dir="$remote_agent/.versiones/$version_local"

  echo "📤 Copiando proyecto local a '$target:$workspace'..."
  ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$workspace' '/home/$user/agent-runner'"
  rsync -az --exclude='.git/' --exclude='vendor/' --exclude='node_modules/' --exclude='.env' \
    "$project_local_path/" "$target:$workspace/"

  echo "📤 Copiando agent-runner local..."
  rsync -az --exclude='.git/' --exclude='.venv/' --exclude='__pycache__/' \
    "$runner_local_path/" "$target:/home/$user/agent-runner/"

  if [ "$agent_update_mode" = "local" ]; then
    echo "📤 Copiando agente local '$stack'..."
    ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$version_dir'"
    rsync -az --exclude='.git/' "$local_agent_path/" "$target:$version_dir/"
    ssh "${SSH_OPTS[@]}" "$target" \
      "test -s '$version_dir/SKILL.md' && printf '%s\n' '$version_local' > '$version_dir/.agent-version' && printf '%s\n' local > '$version_dir/.git-commit' && ln -sfn '.versiones/$version_local' '$remote_agent/actual.nuevo' && mv -Tf '$remote_agent/actual.nuevo' '$remote_agent/actual'"
  fi
}

if [ "$source_mode" = "local" ] && [ "$modo" = "provisionar" ]; then
  COPIAR_FUENTES_LOCALES
fi

ENVIAR_CONFIG() {
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$VM_PROFILE" "$stack" "$source_mode" "$agent_update_mode" "$workspace" "$project_git_url" "$project_git_branch" \
    "$runner_bin" "$runner_git_url" "$runner_git_branch" "$node_version" \
    "$opencode_version" "$php_version" "$php_min_version" "$install_dependencies" "$remote_agent" "$agent_git_url" \
    "$agent_git_branch" "$agent_git_path" "$agent_poll_seconds" "${GITHUB_TOKEN:-}"
}

if ENVIAR_CONFIG | ssh "${SSH_OPTS[@]}" "$target" "'$remote_bootstrap' '$modo'"; then
  :
else
  codigo=$?
  if [ "$codigo" -eq 20 ] && [ "$OPCION" != "--con-sudo-interactivo" ]; then
    echo "Reintenta con: ./tools/provisionar_vm.sh $VM_PROFILE --con-sudo-interactivo" >&2
  fi
  exit "$codigo"
fi

if [ "$modo" = "verificar" ]; then
  exit 0
fi

if [ "$agent_update_mode" = "git" ]; then
  "$ROOT/tools/instalar_actualizacion_git.sh" "$VM_PROFILE"
else
  echo "✓ Agente instalado desde la Mac; no se configura cron Git para '$VM_PROFILE'."
fi

ENVIAR_CONFIG | ssh "${SSH_OPTS[@]}" "$target" "'$remote_bootstrap' verificar"
if [ "$agent_update_mode" = "local" ]; then
  "$ROOT/tools/instalar_monitor_local.sh"
fi
echo "✅ Provisionamiento completo de '$VM_PROFILE' como '$stack' finalizado."
