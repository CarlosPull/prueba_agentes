#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/orquestador-harness-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export PATH="$ROOT/tests/fakes:$PATH"
export OPENAI_API_KEY="CLAVE_PRUEBA_NO_DEBE_IR_EN_ARGV"

"$ROOT/tools/probar_vms.sh" >/dev/null

project="$TEST_TMP/proyecto"
mkdir -p "$project"

"$ROOT/tools/validar_y_despachar.sh" backend "$project" "Crear endpoint de prueba" >/dev/null
"$ROOT/tools/validar_y_despachar.sh" frontend "$project" "Crear componente de prueba" >/dev/null

if "$ROOT/tools/validar_y_despachar.sh" backend "$project" "Duplicado" >/dev/null 2>&1; then
  echo "El lock permitió despachar backend dos veces" >&2
  exit 1
fi

"$ROOT/tools/generar_reporte.sh" "$project" "Prueba integral" >/dev/null

grep -q -- '- Estado harness: completed' "$project/AGENT_HARNESS.md"
grep -q -- 'Ejecución simulada correcta' "$project/AGENT_HARNESS.md"
grep -q -- 'QA' "$project/AGENT_HARNESS.md" || grep -q -- 'Rol: qa' "$project/AGENT_HARNESS.md"

echo "✅ Adaptador de Agent Harness verificado con SSH simulado."
