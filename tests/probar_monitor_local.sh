#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/home"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEMP_DIR/bin/launchctl"
chmod +x "$TEMP_DIR/bin/launchctl"

HOME="$TEMP_DIR/home" PATH="$TEMP_DIR/bin:$PATH" "$ROOT/tools/instalar_monitor_local.sh" >/dev/null

plist="$TEMP_DIR/home/Library/LaunchAgents/com.prueba-agentes.sincronizacion-local.plist"
test -s "$plist"
plutil -lint "$plist" >/dev/null
grep -q '<integer>30</integer>' "$plist"
grep -q 'monitor_agentes_locales.sh' "$plist"
grep -q '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$plist"

echo "✓ LaunchAgent local y frecuencia de 30 segundos verificados."
