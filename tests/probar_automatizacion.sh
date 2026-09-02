#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "$ROOT/tools" "$ROOT/pi-harness/bin" -type f -name '*.sh' -exec bash -n {} +
jq empty "$ROOT/config/vms.json"

for prueba in \
  probar_clasificacion.sh \
  probar_enrutamiento_modular.sh \
  probar_despacho_paralelo.sh \
  probar_pi_harness.sh \
  probar_provisionamiento_pi.sh \
  probar_sincronizacion.sh \
  probar_ciclo_actualizacion.sh \
  probar_monitor_local.sh \
  probar_creacion_agente.sh \
  probar_consultar_memoria.sh; do
  bash "$ROOT/tests/$prueba"
done

node "$ROOT/tests/probar_extension_pi.mjs"
node "$ROOT/tests/probar_memory_gateway.mjs"
python3 "$ROOT/tests/probar_visualizador_grafos.py"

echo "✓ Automatización local completa verificada."
