#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r script; do bash -n "$script"; done < <(find "$ROOT/tools" "$ROOT/pi-harness/bin" -type f -name '*.sh')
bash -n "$ROOT/pi-harness/bin/pi-harness"
jq empty "$ROOT/config/vms.json"
# La suite determinista no debe depender de un servicio Ollama local activo.
export PRUEBA_AGENTES_DISABLE_LLM_ANALYSIS=1
python3 "$ROOT/tests/probar_analista_llm.py"

for prueba in \
  probar_candado_despacho.sh \
  probar_clasificacion.sh \
  probar_enrutamiento_modular.sh \
  probar_despacho_paralelo.sh \
  probar_pi_harness.sh \
  probar_config_vms_normalizada.sh \
  probar_provisionamiento_pi.sh \
  probar_sincronizacion.sh \
  probar_ciclo_actualizacion.sh \
  probar_monitor_local.sh \
  probar_creacion_agente.sh \
  probar_consultar_memoria.sh \
  probar_actualizar_memoria_negocio.sh; do
  bash "$ROOT/tests/$prueba"
done

node "$ROOT/tests/probar_extension_pi.mjs"
node "$ROOT/tests/probar_memory_gateway.mjs"
python3 "$ROOT/tests/probar_visualizador_grafos.py"

echo "✓ Automatización local completa verificada."
