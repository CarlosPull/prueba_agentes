#!/usr/bin/env bash
# Verifica el funcionamiento del CLI tools/gateway/consultar_memoria.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/gateway/consultar_memoria.sh"

bash -n "$SCRIPT"

"$SCRIPT" >/dev/null
"$SCRIPT" --contratos | grep -F "POST" >/dev/null
"$SCRIPT" --buscar stats | grep -F "stats" >/dev/null
"$SCRIPT" --ver GET "/api/posts/{id}/stats" | grep -F "word_count" >/dev/null

echo "✓ Script consultar_memoria.sh verificado correctamente."
