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

php_compatible=0
if command -v php >/dev/null 2>&1; then
  php -r "exit(version_compare(PHP_VERSION, '$php_min_version', '>=') ? 0 : 1);" && php_compatible=1
fi

if [ "$php_compatible" -ne 1 ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *)
      echo "Error: PHP $php_version no está disponible en el repositorio base y el PPA configurado solo soporta Ubuntu LTS compatible." >&2
      exit 1
      ;;
  esac
  sudo add-apt-repository -y ppa:ondrej/php
  sudo apt-get update
fi

sudo apt-get install -y \
  "php$php_version-cli" "php$php_version-mbstring" "php$php_version-xml" \
  "php$php_version-curl" "php$php_version-zip" "php$php_version-intl" \
  "php$php_version-bcmath" "php$php_version-sqlite3" composer unzip

sudo update-alternatives --set php "/usr/bin/php$php_version"
[ ! -x "/usr/bin/phar$php_version" ] || sudo update-alternatives --set phar "/usr/bin/phar$php_version"
[ ! -x "/usr/bin/phar.phar$php_version" ] || sudo update-alternatives --set phar.phar "/usr/bin/phar.phar$php_version"
sudo systemctl enable --now cron

php -r "if (!version_compare(PHP_VERSION, '$php_min_version', '>=')) { fwrite(STDERR, 'PHP insuficiente: '.PHP_VERSION.PHP_EOL); exit(1); }"
echo "✓ PHP $(php -r 'echo PHP_VERSION;') y paquetes backend instalados."
