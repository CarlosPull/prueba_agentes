#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT"/tools/*.sh "$ROOT"/tools/remotos/*.sh
jq empty "$ROOT/vms.json"
grep -A5 '^LIMPIAR()' "$ROOT/tools/remotos/provisionar_vm.sh" | grep -q 'return 0'
"$ROOT/tests/probar_sincronizacion.sh"
"$ROOT/tests/probar_ciclo_actualizacion.sh"
"$ROOT/tests/probar_monitor_local.sh"

echo "✓ Automatización local completa verificada."
