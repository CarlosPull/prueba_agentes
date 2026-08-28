#!/usr/bin/env bash
# Bootstrap idempotente que se instala y ejecuta dentro de una VM de agente.
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

MODO="${1:-provisionar}"
if [ "$MODO" != "provisionar" ] && [ "$MODO" != "verificar" ]; then
  echo "Error: modo remoto no válido: '$MODO'." >&2
  exit 1
fi

IFS= read -r VM_PROFILE
IFS= read -r STACK
IFS= read -r SOURCE_MODE
IFS= read -r AGENT_UPDATE_MODE
IFS= read -r WORKSPACE
IFS= read -r PROJECT_GIT_URL
IFS= read -r PROJECT_GIT_BRANCH
IFS= read -r RUNNER_BIN
IFS= read -r RUNNER_GIT_URL
IFS= read -r RUNNER_GIT_BRANCH
IFS= read -r NODE_VERSION
IFS= read -r OPENCODE_VERSION
IFS= read -r PHP_VERSION_DESEADA
IFS= read -r PHP_MIN_VERSION
IFS= read -r INSTALL_DEPENDENCIES
IFS= read -r REMOTE_AGENT
IFS= read -r AGENT_GIT_URL
IFS= read -r AGENT_GIT_BRANCH
IFS= read -r AGENT_GIT_PATH
IFS= read -r AGENT_POLL_SECONDS
IFS= read -r GITHUB_TOKEN || GITHUB_TOKEN=""

VALIDAR_RUTA_HOME() {
  local ruta="$1"
  if [[ ! "$ruta" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: ruta remota fuera de /home/<usuario>: '$ruta'." >&2
    exit 1
  fi
}

VALIDAR_URL_GIT() {
  local url="$1"
  if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]]; then
    echo "Error: URL Git no permitida: '$url'." >&2
    exit 1
  fi
}

if [[ ! "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]] || [[ ! "$STACK" =~ ^(backend|frontend)$ ]]; then
  echo "Error: perfil de VM o stack no soportado." >&2
  exit 1
fi
if [ "$SOURCE_MODE" != "git" ] && [ "$SOURCE_MODE" != "local" ]; then
  echo "Error: modo de fuentes no válido." >&2
  exit 1
fi
if [ "$AGENT_UPDATE_MODE" != "git" ] && [ "$AGENT_UPDATE_MODE" != "local" ]; then
  echo "Error: modo de actualización del agente no válido." >&2
  exit 1
fi
if [ "$SOURCE_MODE" = "git" ]; then
  if [[ ! "$PROJECT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! "$RUNNER_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: rama Git no válida." >&2
    exit 1
  fi
fi
if [ "$AGENT_UPDATE_MODE" = "git" ]; then
  if [[ ! "$AGENT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! "$AGENT_GIT_PATH" =~ ^skills/[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: rama o ruta Git del agente no válida." >&2
    exit 1
  fi
  case "$AGENT_POLL_SECONDS" in
    10|15|20|30|60) ;;
    *) echo "Error: intervalo Git del agente no válido." >&2; exit 1 ;;
  esac
fi
if [[ ! "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$OPENCODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: versión de Node u OpenCode no válida." >&2
  exit 1
fi
if [ "$STACK" = "backend" ]; then
  if [[ ! "$PHP_VERSION_DESEADA" =~ ^[0-9]+\.[0-9]+$ ]] || [[ ! "$PHP_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: versión PHP deseada o mínima no válida." >&2
    exit 1
  fi
fi
if [ "$INSTALL_DEPENDENCIES" != "true" ] && [ "$INSTALL_DEPENDENCIES" != "false" ]; then
  echo "Error: install_dependencies debe ser true o false." >&2
  exit 1
fi

VALIDAR_RUTA_HOME "$WORKSPACE"
VALIDAR_RUTA_HOME "$RUNNER_BIN"
VALIDAR_RUTA_HOME "$REMOTE_AGENT"
if [ "$SOURCE_MODE" = "git" ]; then
  VALIDAR_URL_GIT "$PROJECT_GIT_URL"
  VALIDAR_URL_GIT "$RUNNER_GIT_URL"
fi
if [ "$AGENT_UPDATE_MODE" = "git" ]; then
  VALIDAR_URL_GIT "$AGENT_GIT_URL"
fi

faltantes=()
for comando in git curl crontab tar flock python3; do
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
  echo "Ejecuta nuevamente el provisionador con --con-sudo-interactivo." >&2
  exit 20
fi
if ! systemctl is-active --quiet cron; then
  echo "REQUISITO_SISTEMA_FALTANTE: servicio cron inactivo." >&2
  exit 20
fi

NVM_DIR="$HOME/.nvm"
NODE_BIN="$NVM_DIR/versions/node/v$NODE_VERSION/bin"
RUNNER_REPO="$HOME/agent-runner"
ASKPASS=""

LIMPIAR() {
  if [ -n "$ASKPASS" ]; then
    rm -f "$ASKPASS"
  fi
  return 0
}
trap LIMPIAR EXIT

CONFIGURAR_GIT_PRIVADO() {
  if [ -z "$GITHUB_TOKEN" ]; then
    export GIT_TERMINAL_PROMPT=0
    return
  fi

  ASKPASS="$(mktemp "$HOME/.git-askpass.XXXXXX")"
  chmod 700 "$ASKPASS"
  printf '%s\n' '#!/usr/bin/env bash' > "$ASKPASS"
  printf '%s\n' 'case "$1" in' >> "$ASKPASS"
  printf '%s\n' '  *Username*) printf "%s\n" "x-access-token" ;;' >> "$ASKPASS"
  printf '%s\n' '  *Password*) printf "%s\n" "$PROVISION_GITHUB_TOKEN" ;;' >> "$ASKPASS"
  printf '%s\n' 'esac' >> "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
  export GIT_TERMINAL_PROMPT=0
  export PROVISION_GITHUB_TOKEN="$GITHUB_TOKEN"
}

ACTUALIZAR_REPOSITORIO() {
  local url="$1"
  local rama="$2"
  local destino="$3"
  local nombre="$4"

  if [ ! -d "$destino/.git" ]; then
    echo "📥 Clonando $nombre..."
    git clone --branch "$rama" --single-branch "$url" "$destino"
    return
  fi

  remote_actual="$(git -C "$destino" remote get-url origin 2>/dev/null || true)"
  if [ "$remote_actual" != "$url" ]; then
    echo "Error: $nombre usa un origin diferente: '$remote_actual'." >&2
    exit 1
  fi

  if [ -n "$(git -C "$destino" status --porcelain)" ]; then
    echo "⚠️ $nombre tiene cambios locales; se preserva sin hacer pull."
    return
  fi

  git -C "$destino" fetch --prune origin "$rama"
  rama_actual="$(git -C "$destino" branch --show-current)"
  if [ "$rama_actual" != "$rama" ]; then
    git -C "$destino" checkout "$rama"
  fi
  git -C "$destino" pull --ff-only origin "$rama"
}

VERIFICAR() {
  local errores=0
  local valor
  local cron_actual

  echo "🔎 Verificando VM '$VM_PROFILE' como '$STACK'..."
  test -d "$WORKSPACE" || { echo "❌ Falta proyecto: $WORKSPACE"; errores=1; }
  test -d "$RUNNER_REPO" || { echo "❌ Falta agent-runner: $RUNNER_REPO"; errores=1; }
  if [ "$SOURCE_MODE" = "git" ] && [ -d "$WORKSPACE/.git" ]; then
    valor="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || true)"
    [ "$valor" = "$PROJECT_GIT_URL" ] || { echo "❌ Origin inesperado en el proyecto: $valor"; errores=1; }
    valor="$(git -C "$WORKSPACE" branch --show-current 2>/dev/null || true)"
    [ "$valor" = "$PROJECT_GIT_BRANCH" ] || { echo "❌ Rama inesperada en el proyecto: $valor"; errores=1; }
  fi
  if [ "$SOURCE_MODE" = "git" ] && [ -d "$RUNNER_REPO/.git" ]; then
    valor="$(git -C "$RUNNER_REPO" remote get-url origin 2>/dev/null || true)"
    [ "$valor" = "$RUNNER_GIT_URL" ] || { echo "❌ Origin inesperado en agent-runner: $valor"; errores=1; }
    valor="$(git -C "$RUNNER_REPO" branch --show-current 2>/dev/null || true)"
    [ "$valor" = "$RUNNER_GIT_BRANCH" ] || { echo "❌ Rama inesperada en agent-runner: $valor"; errores=1; }
  fi
  test -x "$RUNNER_BIN" || { echo "❌ Falta ejecutable: $RUNNER_BIN"; errores=1; }
  test -x "$NODE_BIN/node" || { echo "❌ Falta Node $NODE_VERSION"; errores=1; }
  test -x "$NODE_BIN/opencode" || { echo "❌ Falta OpenCode en $NODE_BIN"; errores=1; }
  if [ "$AGENT_UPDATE_MODE" = "git" ]; then
    test -x "$REMOTE_AGENT/actualizar_desde_git.sh" || { echo "❌ Falta actualizador Git del agente"; errores=1; }
    test -x "$REMOTE_AGENT/ciclo_actualizacion_git.sh" || { echo "❌ Falta ciclo periódico del agente"; errores=1; }
    test -s "$REMOTE_AGENT/git-agent.conf" || { echo "❌ Falta git-agent.conf"; errores=1; }
  fi
  if [ "$AGENT_UPDATE_MODE" = "git" ] && [ -s "$REMOTE_AGENT/git-agent.conf" ]; then
    [ "$(sed -n '1p' "$REMOTE_AGENT/git-agent.conf")" = "$AGENT_GIT_URL" ] || { echo "❌ URL incorrecta en git-agent.conf"; errores=1; }
    [ "$(sed -n '2p' "$REMOTE_AGENT/git-agent.conf")" = "$AGENT_GIT_BRANCH" ] || { echo "❌ Rama incorrecta en git-agent.conf"; errores=1; }
    [ "$(sed -n '3p' "$REMOTE_AGENT/git-agent.conf")" = "$STACK" ] || { echo "❌ Rol incorrecto en git-agent.conf"; errores=1; }
    [ "$(sed -n '4p' "$REMOTE_AGENT/git-agent.conf")" = "$AGENT_GIT_PATH" ] || { echo "❌ Ruta incorrecta en git-agent.conf"; errores=1; }
    [ "$(sed -n '5p' "$REMOTE_AGENT/git-agent.conf")" = "$AGENT_POLL_SECONDS" ] || { echo "❌ Intervalo incorrecto en git-agent.conf"; errores=1; }
  fi
  test -s "$REMOTE_AGENT/actual/SKILL.md" || { echo "❌ Falta agente activo"; errores=1; }
  test -s "$REMOTE_AGENT/actual/.git-commit" || { echo "❌ Falta commit activo del agente"; errores=1; }
  if [ "$AGENT_UPDATE_MODE" = "git" ]; then
    cron_actual="$(crontab -l 2>/dev/null || true)"
    printf '%s\n' "$cron_actual" | grep -F "# prueba-agentes-$VM_PROFILE" >/dev/null || { echo "❌ Falta cron del agente"; errores=1; }
    printf '%s\n' "$cron_actual" | grep -F "$REMOTE_AGENT/ciclo_actualizacion_git.sh" >/dev/null || { echo "❌ El cron no usa el ciclo periódico del agente"; errores=1; }
  fi

  if [ -x "$RUNNER_BIN" ] && [ -x "$NODE_BIN/opencode" ]; then
    PATH="$NODE_BIN:$HOME/.local/bin:$PATH" "$RUNNER_BIN" doctor >/dev/null || {
      echo "❌ agent-runner doctor falló"
      errores=1
    }
  fi

  if [ "$errores" -ne 0 ]; then
    return 1
  fi
  echo "✅ VM '$VM_PROFILE' lista como '$STACK': repositorios, runtimes, agent-runner, agente y cron verificados."
}

if [ "$MODO" = "verificar" ]; then
  VERIFICAR
  exit
fi

if [ "$SOURCE_MODE" = "git" ]; then
  CONFIGURAR_GIT_PRIVADO
fi

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "📦 Instalando NVM..."
  git clone --branch v0.40.3 --depth 1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
fi
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
export PATH="$NODE_BIN:$HOME/.local/bin:$PATH"

version_opencode="$(opencode --version 2>/dev/null || true)"
if [ "$version_opencode" != "$OPENCODE_VERSION" ]; then
  echo "📦 Instalando OpenCode $OPENCODE_VERSION..."
  npm install -g "opencode-ai@$OPENCODE_VERSION"
fi

if [ "$SOURCE_MODE" = "git" ]; then
  ACTUALIZAR_REPOSITORIO "$RUNNER_GIT_URL" "$RUNNER_GIT_BRANCH" "$RUNNER_REPO" "agent-runner"
else
  test -d "$RUNNER_REPO" || { echo "Error: falta copia local de agent-runner." >&2; exit 1; }
fi
python3 -m pip install --user --break-system-packages -e "$RUNNER_REPO"

if [ "$SOURCE_MODE" = "git" ]; then
  ACTUALIZAR_REPOSITORIO "$PROJECT_GIT_URL" "$PROJECT_GIT_BRANCH" "$WORKSPACE" "proyecto $STACK"
else
  test -d "$WORKSPACE" || { echo "Error: falta copia local del proyecto." >&2; exit 1; }
fi

if [ "$INSTALL_DEPENDENCIES" = "true" ]; then
  if [ "$STACK" = "backend" ]; then
    composer install --working-dir="$WORKSPACE" --no-interaction --prefer-dist
    if [ ! -f "$WORKSPACE/.env" ] && [ -f "$WORKSPACE/.env.example" ]; then
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

echo "✓ Bootstrap base de '$VM_PROFILE' como '$STACK' completado."
