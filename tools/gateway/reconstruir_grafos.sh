#!/usr/bin/env bash
# Reconstruye los grafos semánticos en Cognee a partir de los contratos guardados en SQLite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export MEMORY_GATEWAY_DB="${MEMORY_GATEWAY_DB:-$ROOT/.private/memory-gateway-data/gateway.sqlite}"
export MEMORY_GATEWAY_CLIENTS="${MEMORY_GATEWAY_CLIENTS:-$ROOT/.private/memory-gateway-clients.json}"
export MEMORY_GATEWAY_OPENAPI_DIR="${MEMORY_GATEWAY_OPENAPI_DIR:-$ROOT/.private/memory-gateway-data/openapi}"
export COGNEE_BASE_URL="${COGNEE_BASE_URL:-http://127.0.0.1:8000}"

command -v node >/dev/null 2>&1 || { echo "Error: node es necesario para sincronizar los grafos." >&2; exit 1; }

echo "🔄 Reconstruyendo grafos de memoria desde SQLite hacia Cognee..."
node "$ROOT/memory-gateway/bin/reconstruir-grafos.mjs" --confirmar-limpieza
echo "✅ Grafos de memoria sincronizados correctamente."
