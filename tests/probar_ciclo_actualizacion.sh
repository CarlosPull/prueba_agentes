#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cp "$ROOT/tools/remotos/ciclo_actualizacion_git.sh" "$TEMP_DIR/ciclo_actualizacion_git.sh"
chmod +x "$TEMP_DIR/ciclo_actualizacion_git.sh"
printf '%s\n%s\n%s\n%s\n%s\n' \
  'https://github.com/ejemplo/orquestador.git' 'rama-prueba' 'backend' 'skills/dev-back' '15' \
  > "$TEMP_DIR/git-agent.conf"

printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''actualizacion\n'\'' >> "$BASE_PRUEBA/conteo.log"' \
  > "$TEMP_DIR/actualizar_desde_git.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$1" >> "$BASE_PRUEBA/esperas.log"' \
  > "$TEMP_DIR/sleep"
chmod +x "$TEMP_DIR/actualizar_desde_git.sh" "$TEMP_DIR/sleep"

export BASE_PRUEBA="$TEMP_DIR"
PATH="$TEMP_DIR:$PATH" "$TEMP_DIR/ciclo_actualizacion_git.sh"

test "$(wc -l < "$TEMP_DIR/conteo.log" | tr -d ' ')" = "4"
test "$(wc -l < "$TEMP_DIR/esperas.log" | tr -d ' ')" = "3"
test "$(sort -u "$TEMP_DIR/esperas.log")" = "15"

sed -i.bak '5s/15/7/' "$TEMP_DIR/git-agent.conf"
if PATH="$TEMP_DIR:$PATH" "$TEMP_DIR/ciclo_actualizacion_git.sh" >/dev/null 2>&1; then
  echo "Error: el ciclo aceptó un intervalo no permitido." >&2
  exit 1
fi

echo "✓ Ciclo subminuto e intervalo seguro verificados."
