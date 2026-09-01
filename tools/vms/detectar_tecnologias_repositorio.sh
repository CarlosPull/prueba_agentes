#!/usr/bin/env bash
# Detecta tecnologías declaradas por un repositorio sin ejecutar su código.
set -euo pipefail

REPOSITORY_PATH="${1:-}"
KIND="${2:-module}"

if [ -z "$REPOSITORY_PATH" ]; then
  echo "Uso: ./tools/vms/detectar_tecnologias_repositorio.sh <ruta-repositorio> [core|module|frontend]" >&2
  exit 1
fi
[ -d "$REPOSITORY_PATH" ] || { echo "Error: no existe el repositorio '$REPOSITORY_PATH'." >&2; exit 1; }
case "$KIND" in core|module|frontend) ;; *) echo "Error: tipo inválido; usa core, module o frontend." >&2; exit 1 ;; esac
command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }

technologies=()
sources=()

ADD_UNIQUE() {
  local value="$1" existing
  [ -n "$value" ] || return 0
  for existing in "${technologies[@]:-}"; do [ "$existing" != "$value" ] || return 0; done
  technologies+=("$value")
}

ADD_SOURCE() {
  local value="$1" existing
  for existing in "${sources[@]:-}"; do [ "$existing" != "$value" ] || return 0; done
  sources+=("$value")
}

ADD_VERSIONED() {
  local name="$1" version="${2:-}"
  if [ -n "$version" ] && [ "$version" != "*" ]; then ADD_UNIQUE "$name $version"; else ADD_UNIQUE "$name"; fi
}

DEPENDENCY_VERSION() {
  local manifest="$1" dependency="$2"
  jq -r --arg dependency "$dependency" '.dependencies[$dependency] // .devDependencies[$dependency] // .peerDependencies[$dependency] // empty' "$manifest"
}

composer="$REPOSITORY_PATH/composer.json"
if [ -s "$composer" ]; then
  jq -e 'type == "object" and ((.require // {}) | type == "object")' "$composer" >/dev/null || {
    echo "Error: composer.json inválido en '$REPOSITORY_PATH'." >&2; exit 1;
  }
  ADD_SOURCE "composer.json"
  ADD_VERSIONED "PHP" "$(jq -r '.require.php // empty' "$composer")"
  laravel_version="$(jq -r '.require["laravel/framework"] // empty' "$composer")"
  if [ -n "$laravel_version" ]; then
    ADD_VERSIONED "Laravel" "$laravel_version"
  elif jq -e '[(.require // {}) + (."require-dev" // {}) | keys[] | select(startswith("illuminate/"))] | length > 0' "$composer" >/dev/null; then
    illuminate_version="$(jq -r '((.require // {}) + (."require-dev" // {})) | to_entries | map(select(.key | startswith("illuminate/"))) | .[0].value // empty' "$composer")"
    ADD_VERSIONED "Illuminate" "$illuminate_version"
  fi
  ADD_UNIQUE "Composer"
fi

package="$REPOSITORY_PATH/package.json"
if [ -s "$package" ]; then
  jq -e 'type == "object" and ((.dependencies // {}) | type == "object") and ((.devDependencies // {}) | type == "object")' "$package" >/dev/null || {
    echo "Error: package.json inválido en '$REPOSITORY_PATH'." >&2; exit 1;
  }
  ADD_SOURCE "package.json"
  ADD_VERSIONED "Node.js" "$(jq -r '.engines.node // empty' "$package")"
  for dependency in vue react next nuxt vite typescript; do
    version="$(DEPENDENCY_VERSION "$package" "$dependency")"
    case "$dependency" in
      vue) name="Vue" ;;
      react) name="React" ;;
      next) name="Next.js" ;;
      nuxt) name="Nuxt" ;;
      vite) name="Vite" ;;
      typescript) name="TypeScript" ;;
    esac
    [ -z "$version" ] || ADD_VERSIONED "$name" "$version"
  done
  package_manager="$(jq -r '.packageManager // empty' "$package")"
  if [ -n "$package_manager" ]; then
    manager_name="${package_manager%%@*}"
    manager_version="${package_manager#*@}"
    [ "$manager_name" != "$manager_version" ] || manager_version=""
    case "$manager_name" in npm) manager_name="npm" ;; pnpm) manager_name="pnpm" ;; yarn) manager_name="Yarn" ;; bun) manager_name="Bun" ;; esac
    ADD_VERSIONED "$manager_name" "$manager_version"
  elif [ -s "$REPOSITORY_PATH/pnpm-lock.yaml" ]; then ADD_UNIQUE "pnpm"
  elif [ -s "$REPOSITORY_PATH/yarn.lock" ]; then ADD_UNIQUE "Yarn"
  elif [ -s "$REPOSITORY_PATH/bun.lockb" ] || [ -s "$REPOSITORY_PATH/bun.lock" ]; then ADD_UNIQUE "Bun"
  else ADD_UNIQUE "npm"
  fi
fi

if [ -s "$REPOSITORY_PATH/pyproject.toml" ] || [ -s "$REPOSITORY_PATH/requirements.txt" ]; then
  [ ! -s "$REPOSITORY_PATH/pyproject.toml" ] || ADD_SOURCE "pyproject.toml"
  [ ! -s "$REPOSITORY_PATH/requirements.txt" ] || ADD_SOURCE "requirements.txt"
  python_version=""
  if [ -s "$REPOSITORY_PATH/pyproject.toml" ]; then
    python_version="$(sed -nE 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$REPOSITORY_PATH/pyproject.toml" | head -n 1)"
  fi
  ADD_VERSIONED "Python" "$python_version"
  ADD_UNIQUE "pip"
fi

if [ -s "$REPOSITORY_PATH/go.mod" ]; then
  ADD_SOURCE "go.mod"
  ADD_VERSIONED "Go" "$(awk '$1 == "go" {print $2; exit}' "$REPOSITORY_PATH/go.mod")"
fi
if [ -s "$REPOSITORY_PATH/Cargo.toml" ]; then ADD_SOURCE "Cargo.toml"; ADD_UNIQUE "Rust"; ADD_UNIQUE "Cargo"; fi
if [ -s "$REPOSITORY_PATH/Gemfile" ]; then ADD_SOURCE "Gemfile"; ADD_UNIQUE "Ruby"; ADD_UNIQUE "Bundler"; fi
if [ -s "$REPOSITORY_PATH/pom.xml" ]; then ADD_SOURCE "pom.xml"; ADD_UNIQUE "Java"; ADD_UNIQUE "Maven"; fi
if [ -s "$REPOSITORY_PATH/build.gradle" ] || [ -s "$REPOSITORY_PATH/build.gradle.kts" ]; then ADD_SOURCE "Gradle"; ADD_UNIQUE "Gradle"; fi
if find "$REPOSITORY_PATH" -maxdepth 2 -type f -name '*.csproj' -print -quit | grep -q .; then ADD_SOURCE "*.csproj"; ADD_UNIQUE ".NET"; fi
if [ -s "$REPOSITORY_PATH/Dockerfile" ] || [ -s "$REPOSITORY_PATH/compose.yaml" ] || [ -s "$REPOSITORY_PATH/docker-compose.yml" ]; then ADD_SOURCE "Docker"; ADD_UNIQUE "Docker"; fi

architecture="repositorio de software"
case "$KIND" in
  core) architecture="core de aplicación" ;;
  module) architecture="módulo de aplicación" ;;
  frontend) architecture="aplicación frontend" ;;
esac
if printf '%s\n' "${technologies[@]:-}" | grep -q '^Laravel'; then
  [ "$KIND" = "core" ] && architecture="core Laravel" || architecture="módulo backend Laravel/Composer"
elif printf '%s\n' "${technologies[@]:-}" | grep -q '^Illuminate'; then
  architecture="módulo backend Illuminate/Composer"
elif printf '%s\n' "${technologies[@]:-}" | grep -q '^Vue'; then
  architecture="aplicación frontend Vue"
elif printf '%s\n' "${technologies[@]:-}" | grep -q '^React'; then
  architecture="aplicación frontend React"
fi

technologies_json="$(printf '%s\n' "${technologies[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
sources_json="$(printf '%s\n' "${sources[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
jq -n --argjson technologies "$technologies_json" --arg architecture "$architecture" --argjson sources "$sources_json" '
  {
    technologies:$technologies,
    architecture:$architecture,
    constraints:[],
    detection:{mode:"automatic",sources:$sources}
  }
'
