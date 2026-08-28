#!/usr/bin/env bash
# Ejecuta varias comprobaciones dentro de cada minuto sin solapar ciclos de cron.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$BASE/git-agent.conf"
ACTUALIZADOR="$BASE/actualizar_desde_git.sh"

intervalo="$(sed -n '5p' "$CONFIG")"
case "$intervalo" in
  10|15|20|30|60) ;;
  *)
    echo "Error: intervalo Git no permitido: '$intervalo'." >&2
    exit 1
    ;;
esac

iteraciones=$((60 / intervalo))
actual=1
while [ "$actual" -le "$iteraciones" ]; do
  "$ACTUALIZADOR"
  if [ "$actual" -lt "$iteraciones" ]; then
    sleep "$intervalo"
  fi
  actual=$((actual + 1))
done
