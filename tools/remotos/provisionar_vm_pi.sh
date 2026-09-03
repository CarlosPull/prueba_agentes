#!/usr/bin/env bash
# Bootstrap idempotente ejecutado dentro de una VM Linux para instalar Pi.
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

MODO="${1:-provisionar}"
[ "$MODO" = "provisionar" ] || [ "$MODO" = "verificar" ] || {
  echo "Error: modo remoto no válido: '$MODO'." >&2
  exit 1
}

IFS= read -r VM_PROFILE
IFS= read -r STACK
IFS= read -r PROJECT_KIND
IFS= read -r SOURCE_MODE
IFS= read -r AGENT_UPDATE_MODE
IFS= read -r WORKSPACE
IFS= read -r PROJECT_GIT_URL
IFS= read -r PROJECT_GIT_BRANCH
IFS= read -r NODE_VERSION
IFS= read -r PI_VERSION
IFS= read -r PHP_MIN_VERSION
IFS= read -r INSTALL_DEPENDENCIES
IFS= read -r REMOTE_AGENT
IFS= read -r AGENT_GIT_URL
IFS= read -r AGENT_GIT_BRANCH
IFS= read -r AGENT_GIT_PATH
IFS= read -r AGENT_POLL_SECONDS
IFS= read -r REMOTE_HARNESS
IFS= read -r PI_HARNESS_BIN
IFS= read -r GITHUB_TOKEN || GITHUB_TOKEN=""

VALIDAR_RUTA_HOME() {
  [[ "$1" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || {
    echo "Error: ruta fuera de /home/<usuario>: '$1'." >&2
    exit 1
  }
}

VALIDAR_URL_GIT() {
  [[ "$1" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || {
    echo "Error: URL Git no permitida: '$1'." >&2
    exit 1
  }
}

[[ "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]] || { echo "Error: perfil no válido." >&2; exit 1; }
[ "$STACK" = "backend" ] || [ "$STACK" = "frontend" ] || { echo "Error: stack no soportado." >&2; exit 1; }
[ "$PROJECT_KIND" = "core" ] || [ "$PROJECT_KIND" = "module" ] || [ "$PROJECT_KIND" = "frontend" ] || { echo "Error: tipo de repositorio no soportado." >&2; exit 1; }
[ "$STACK" != "frontend" ] || [ "$PROJECT_KIND" = "frontend" ] || { echo "Error: una VM frontend requiere kind=frontend." >&2; exit 1; }
[ "$STACK" != "backend" ] || { [ "$PROJECT_KIND" = "core" ] || [ "$PROJECT_KIND" = "module" ]; } || { echo "Error: una VM backend requiere kind=core o kind=module." >&2; exit 1; }
[ "$SOURCE_MODE" = "git" ] || [ "$SOURCE_MODE" = "local" ] || { echo "Error: source_mode no válido." >&2; exit 1; }
[ "$AGENT_UPDATE_MODE" = "git" ] || [ "$AGENT_UPDATE_MODE" = "local" ] || { echo "Error: agent_update_mode no válido." >&2; exit 1; }
[[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: Node no válido." >&2; exit 1; }
[[ "$PI_VERSION" = "latest" || "$PI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Error: versión Pi no válida." >&2; exit 1; }
[ "$INSTALL_DEPENDENCIES" = "true" ] || [ "$INSTALL_DEPENDENCIES" = "false" ] || { echo "Error: install_dependencies no válido." >&2; exit 1; }
VALIDAR_RUTA_HOME "$WORKSPACE"
VALIDAR_RUTA_HOME "$REMOTE_AGENT"
VALIDAR_RUTA_HOME "$REMOTE_HARNESS"
VALIDAR_RUTA_HOME "$PI_HARNESS_BIN"

if [ "$SOURCE_MODE" = "git" ]; then
  VALIDAR_URL_GIT "$PROJECT_GIT_URL"
  [[ "$PROJECT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Error: rama del proyecto no válida." >&2; exit 1; }
fi
if [ "$AGENT_UPDATE_MODE" = "git" ]; then
  VALIDAR_URL_GIT "$AGENT_GIT_URL"
  [[ "$AGENT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Error: rama del agente no válida." >&2; exit 1; }
  [[ "$AGENT_GIT_PATH" =~ ^skills/[A-Za-z0-9._/-]+$ ]] || { echo "Error: ruta del agente no válida." >&2; exit 1; }
  case "$AGENT_POLL_SECONDS" in 10|15|20|30|60) ;; *) echo "Error: intervalo del agente no válido." >&2; exit 1 ;; esac
fi
if [ "$STACK" = "backend" ]; then
  [[ "$PHP_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: PHP mínimo no válido." >&2; exit 1; }
fi

faltantes=()
for comando in git curl crontab tar flock jq bwrap; do
  command -v "$comando" >/dev/null 2>&1 || faltantes+=("$comando")
done
if [ "$STACK" = "backend" ]; then
  command -v php >/dev/null 2>&1 || faltantes+=("php")
  command -v composer >/dev/null 2>&1 || faltantes+=("composer")
  if command -v php >/dev/null 2>&1 && ! php -r "exit(version_compare(PHP_VERSION, '$PHP_MIN_VERSION', '>=') ? 0 : 1);"; then
    faltantes+=("php>=$PHP_MIN_VERSION")
  fi
fi
if [ "${#faltantes[@]}" -gt 0 ]; then
  echo "REQUISITOS_SISTEMA_FALTANTES: ${faltantes[*]}" >&2
  exit 20
fi
systemctl is-active --quiet cron || { echo "REQUISITO_SISTEMA_FALTANTE: cron inactivo." >&2; exit 20; }

NVM_DIR="$HOME/.nvm"
NODE_BIN="$NVM_DIR/versions/node/v$NODE_VERSION/bin"
ASKPASS=""

LIMPIAR() {
  [ -z "$ASKPASS" ] || rm -f "$ASKPASS"
  return 0
}
trap LIMPIAR EXIT

CONFIGURAR_GIT_PRIVADO() {
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  if ! grep -q 'Host github.com' "$HOME/.ssh/config" 2>/dev/null; then
    printf 'Host github.com\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

  if [ -z "$GITHUB_TOKEN" ]; then
    export GIT_TERMINAL_PROMPT=0
    return
  fi
  ASKPASS="$(mktemp "$HOME/.git-askpass.XXXXXX")"
  chmod 700 "$ASKPASS"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' \
    '  *Username*) printf "%s\n" "x-access-token" ;;' \
    '  *Password*) printf "%s\n" "$PROVISION_GITHUB_TOKEN" ;;' 'esac' > "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 PROVISION_GITHUB_TOKEN="$GITHUB_TOKEN"
}


ACTUALIZAR_REPOSITORIO() {
  local url="$1" rama="$2" destino="$3"
  if [ ! -d "$destino/.git" ]; then
    mkdir -p "$(dirname "$destino")"
    if ! git clone --branch "$rama" --single-branch "$url" "$destino" 2>/dev/null; then
      if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)(\.git)?$ ]]; then
        local ssh_url="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}.git"
        echo "ℹ️ Clonación HTTPS requirió autenticación; reintentando por SSH ($ssh_url)..."
        git clone --branch "$rama" --single-branch "$ssh_url" "$destino"
      else
        echo "Error: no se pudo clonar el repositorio '$url'." >&2
        exit 1
      fi
    fi
    return
  fi

  remote_actual="$(git -C "$destino" remote get-url origin 2>/dev/null || true)"
  if [ "$(NORMALIZAR_URL_GIT "$remote_actual")" != "$(NORMALIZAR_URL_GIT "$url")" ]; then
    echo "Error: origin inesperado en '$destino': '$remote_actual' (esperado: '$url')." >&2
    exit 1
  fi
  if [ -n "$(git -C "$destino" status --porcelain)" ]; then
    echo "⚠️ El proyecto tiene cambios locales; no se hace pull."
    return
  fi
  git -C "$destino" fetch --prune origin "$rama"
  [ "$(git -C "$destino" branch --show-current)" = "$rama" ] || git -C "$destino" checkout "$rama"
  git -C "$destino" pull --ff-only origin "$rama"
}

NORMALIZAR_URL_GIT() {
  local u="$1"
  u="${u#git@github.com:}"
  u="${u#https://github.com/}"
  u="${u%.git}"
  printf '%s' "$u"
}

VERIFICAR() {
  local errores=0 valor cron_actual
  echo "🔎 Verificando VM Pi '$VM_PROFILE' como '$STACK'..."
  test -d "$WORKSPACE" || { echo "❌ Falta proyecto: $WORKSPACE"; errores=1; }
  test -x "$NODE_BIN/node" || { echo "❌ Falta Node $NODE_VERSION"; errores=1; }
  test -x "$NODE_BIN/pi" || { echo "❌ Falta Pi en $NODE_BIN"; errores=1; }
  test -x "$PI_HARNESS_BIN" || { echo "❌ Falta pi-harness: $PI_HARNESS_BIN"; errores=1; }
  test -s "$REMOTE_HARNESS/bin/filtrar_salida_pi.sh" || { echo "❌ Falta filtro seguro de salida de Pi"; errores=1; }
  test -s "$REMOTE_HARNESS/extension/index.ts" || { echo "❌ Falta extensión de seguridad de Pi"; errores=1; }
  test -s "$REMOTE_HARNESS/policies/$STACK.json" || { echo "❌ Falta política del stack $STACK"; errores=1; }
  test -s "$REMOTE_AGENT/actual/SKILL.md" || { echo "❌ Falta agente activo"; errores=1; }
  if command -v bwrap >/dev/null 2>&1; then
    bwrap --ro-bind / / --dev /dev --proc /proc -- true >/dev/null 2>&1 || {
      echo "❌ Bubblewrap está instalado, pero el sistema no permite crear el aislamiento"
      echo "   En Ubuntu 24.04 vuelve a ejecutar el provisionador con --con-sudo-interactivo para instalar su perfil AppArmor."
      errores=1
    }
  else
    echo "❌ Falta Bubblewrap"
    errores=1
  fi

  if [ "$SOURCE_MODE" = "git" ] && [ -d "$WORKSPACE/.git" ]; then
    valor="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || true)"
    [ "$(NORMALIZAR_URL_GIT "$valor")" = "$(NORMALIZAR_URL_GIT "$PROJECT_GIT_URL")" ] || { echo "❌ Origin inesperado: $valor"; errores=1; }
    valor="$(git -C "$WORKSPACE" branch --show-current 2>/dev/null || true)"
    [ "$valor" = "$PROJECT_GIT_BRANCH" ] || { echo "❌ Rama inesperada: $valor"; errores=1; }
  fi


  if [ "$AGENT_UPDATE_MODE" = "git" ]; then
    test -x "$REMOTE_AGENT/actualizar_desde_git.sh" || { echo "❌ Falta actualizador Git del agente"; errores=1; }
    cron_actual="$(crontab -l 2>/dev/null || true)"
    printf '%s\n' "$cron_actual" | grep -F "# prueba-agentes-$VM_PROFILE" >/dev/null || { echo "❌ Falta cron del agente"; errores=1; }
  fi

  if [ "$errores" -eq 0 ]; then
    PATH="$NODE_BIN:$HOME/.local/bin:$PATH" "$PI_HARNESS_BIN" doctor \
      --role "$STACK" --workspace "$WORKSPACE" --agent-dir "$REMOTE_AGENT/actual" >/dev/null || errores=1
  fi
  [ "$errores" -eq 0 ] || return 1
  echo "✅ Pi, pi-harness, Bubblewrap, proyecto y agente verificados."
}

if [ "$MODO" = "verificar" ]; then
  VERIFICAR
  exit
fi

test -s "$REMOTE_HARNESS/bin/pi-harness" || { echo "Error: pi-harness no fue copiado a la VM." >&2; exit 1; }
if [ "$SOURCE_MODE" = "git" ]; then CONFIGURAR_GIT_PRIVADO; fi

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "📦 Instalando NVM..."
  git clone --branch v0.40.3 --depth 1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
fi
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
export PATH="$NODE_BIN:$HOME/.local/bin:$PATH"

pi_instalada="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies["@earendil-works/pi-coding-agent"].version // empty' || true)"
if [ "$PI_VERSION" = "latest" ] || [ "$pi_instalada" != "$PI_VERSION" ]; then
  echo "📦 Instalando Pi $PI_VERSION..."
  npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@$PI_VERSION"
fi
command -v pi >/dev/null 2>&1 || { echo "Error: npm terminó pero Pi no está disponible." >&2; exit 1; }

if [ "$SOURCE_MODE" = "git" ]; then
  ACTUALIZAR_REPOSITORIO "$PROJECT_GIT_URL" "$PROJECT_GIT_BRANCH" "$WORKSPACE"
else
  test -d "$WORKSPACE" || { echo "Error: falta la copia local del proyecto." >&2; exit 1; }
fi

if [ "$INSTALL_DEPENDENCIES" = "true" ]; then
  if [ "$STACK" = "backend" ]; then
    composer install --working-dir="$WORKSPACE" --no-interaction --prefer-dist
    if [ "$PROJECT_KIND" = "core" ] && [ ! -f "$WORKSPACE/.env" ] && [ -f "$WORKSPACE/.env.example" ]; then
      cp "$WORKSPACE/.env.example" "$WORKSPACE/.env"
      php "$WORKSPACE/artisan" key:generate --force
    fi
  else
    npm --prefix "$WORKSPACE" ci
    if [ ! -f "$WORKSPACE/.env" ] && [ -f "$WORKSPACE/.env.example" ]; then
      cp "$WORKSPACE/.env.example" "$WORKSPACE/.env"
    fi
  fi
fi

echo "✓ Bootstrap Pi de '$VM_PROFILE' completado."
