#!/usr/bin/env bash
# Instala PHP y dependencias del sistema dentro de una VM backend Ubuntu.
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

php_version="${1:-}"
php_min_version="${2:-}"
shift 2 || true

if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || [[ ! "$php_min_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: versiones PHP no válidas." >&2
  exit 1
fi
if [ "$#" -eq 0 ]; then
  echo "Error: no se recibieron paquetes base." >&2
  exit 1
fi
for paquete in "$@"; do
  [[ "$paquete" =~ ^[a-z0-9.+-]+$ ]] || { echo "Error: paquete no válido: '$paquete'." >&2; exit 1; }
done

sudo apt-get update
sudo apt-get install -y "$@"

# Consultar candidatos APT, no confundir «no instalado» con «no disponible».
candidato_apt() {
  apt-cache policy "$1" | awk '$1 == "Candidate:" && $2 != "(none)" { print $2 }'
}

paquetes_php() {
  local extension
  for extension in cli mbstring xml curl zip intl bcmath sqlite3; do
    printf 'php%s-%s\n' "$1" "$extension"
  done
}

version_disponible() {
  local version="$1" paquete candidato version_upstream
  while IFS= read -r paquete; do
    candidato="$(candidato_apt "$paquete")"
    [ -n "$candidato" ] || return 1
    if [ "$paquete" = "php$version-cli" ]; then
      version_upstream="${candidato#*:}"
      version_upstream="${version_upstream%%-*}"
      dpkg --compare-versions "$version_upstream" ge "$php_min_version" || return 1
    fi
  done < <(paquetes_php "$version")
}

# Se usa /etc/os-release del sistema, nunca una distribución distinta para el PPA.
# shellcheck source=/dev/null
. /etc/os-release

if ! version_disponible "$php_version"; then
  # Preferir la versión nativa si satisface el mínimo dentro de la misma major.
  php_nativo="$(apt-cache depends php-cli | sed -nE 's/^[[:space:]]*Depends: php([0-9]+\.[0-9]+)-cli$/\1/p')"
  if [[ "$php_nativo" =~ ^[0-9]+\.[0-9]+$ ]] \
    && [ "${php_nativo%%.*}" = "${php_version%%.*}" ] \
    && dpkg --compare-versions "$php_nativo" ge "$php_version" \
    && version_disponible "$php_nativo"; then
    echo "Aviso: PHP $php_version no tiene todos los candidatos requeridos; se instalará PHP $php_nativo nativo (mínimo $php_min_version). Composer validará las restricciones del proyecto."
    php_version="$php_nativo"
  else
    case "${ID:-}:${VERSION_ID:-}" in
      ubuntu:22.04|ubuntu:24.04)
        sudo add-apt-repository -y ppa:ondrej/php
        sudo apt-get update
        ;;
      *)
        echo "Error: no hay paquetes PHP $php_version completos ni una versión nativa compatible con el mínimo $php_min_version en ${PRETTY_NAME:-sistema desconocido}. No se añadirá un PPA no validado para esta distribución. Revise los repositorios APT o use una VM Ubuntu 22.04/24.04 compatible con el instalador." >&2
        exit 1
        ;;
    esac
    if ! version_disponible "$php_version"; then
      echo "Error: el PPA no ofrece todos los paquetes PHP $php_version con el mínimo $php_min_version para esta VM." >&2
      exit 1
    fi
  fi
fi

paquetes_php_seleccionados=()
while IFS= read -r paquete; do
  paquetes_php_seleccionados+=("$paquete")
done < <(paquetes_php "$php_version")
sudo apt-get install -y "${paquetes_php_seleccionados[@]}" composer unzip

sudo update-alternatives --set php "/usr/bin/php$php_version"
[ ! -x "/usr/bin/phar$php_version" ] || sudo update-alternatives --set phar "/usr/bin/phar$php_version"
[ ! -x "/usr/bin/phar.phar$php_version" ] || sudo update-alternatives --set phar.phar "/usr/bin/phar.phar$php_version"
sudo systemctl enable --now cron

php -r "if (!version_compare(PHP_VERSION, '$php_min_version', '>=')) { fwrite(STDERR, 'PHP insuficiente: '.PHP_VERSION.PHP_EOL); exit(1); }"
echo "✓ PHP $(php -r 'echo PHP_VERSION;') y paquetes backend instalados."
