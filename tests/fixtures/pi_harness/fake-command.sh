#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$0")" = "pi" ] && [ "${1:-}" = "--version" ]; then
  echo "pi-coding-agent 0.0.0-prueba"
fi
