#!/usr/bin/env bash
# Instala en macOS un LaunchAgent que sincroniza agentes locales cada 30 segundos.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="com.prueba-agentes.sincronizacion-local"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/prueba-agentes"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: el monitor automático local requiere macOS y launchd." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
tmp="$(mktemp "$HOME/Library/LaunchAgents/$LABEL.XXXXXX")"
trap 'rm -f "${tmp:-}"' EXIT

escaped_root="$(printf '%s' "$ROOT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
escaped_log="$(printf '%s' "$LOG_DIR" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"

printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '  <key>Label</key>' "  <string>$LABEL</string>" \
  '  <key>ProgramArguments</key>' \
  '  <array>' \
  '    <string>/bin/bash</string>' \
  "    <string>$escaped_root/tools/monitor_agentes_locales.sh</string>" \
  '  </array>' \
  '  <key>WorkingDirectory</key>' "  <string>$escaped_root</string>" \
  '  <key>EnvironmentVariables</key>' \
  '  <dict>' \
  '    <key>PATH</key>' \
  '    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>' \
  '  </dict>' \
  '  <key>RunAtLoad</key><true/>' \
  '  <key>StartInterval</key><integer>30</integer>' \
  '  <key>StandardOutPath</key>' "  <string>$escaped_log/sincronizacion.log</string>" \
  '  <key>StandardErrorPath</key>' "  <string>$escaped_log/sincronizacion-error.log</string>" \
  '</dict>' \
  '</plist>' > "$tmp"

plutil -lint "$tmp" >/dev/null
mv -f "$tmp" "$PLIST"
trap - EXIT

domain="gui/$(id -u)"
launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$PLIST"
launchctl enable "$domain/$LABEL"
launchctl kickstart -k "$domain/$LABEL"

launchctl print "$domain/$LABEL" >/dev/null
echo "✓ Monitor local instalado: sincronización cada 30 segundos."
