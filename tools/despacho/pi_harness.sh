#!/usr/bin/env bash
# Entrada estable del repositorio al harness experimental de Pi.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$ROOT_DIR/pi-harness/bin/pi-harness" "$@"
