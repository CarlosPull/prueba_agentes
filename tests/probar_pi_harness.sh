#!/usr/bin/env bash
# Pruebas locales del selector de plataforma y del modo fail-closed de Pi.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT_DIR/tools/despacho/pi_harness.sh"
FIXTURE="$ROOT_DIR/tests/fixtures/pi_harness/fake-command.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-pi-harness.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

FAIL() {
  echo "FALLO: $*" >&2
  exit 1
}

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/workspace/app" "$TEMP_DIR/agente" "$TEMP_DIR/runs"
printf '%s\n' '# Agente de prueba' > "$TEMP_DIR/agente/SKILL.md"
printf '%s\n' '<?php' > "$TEMP_DIR/workspace/app/Example.php"

for command_name in pi bwrap sandbox-exec pi-appcontainer; do
  ln -s "$FIXTURE" "$TEMP_DIR/bin/$command_name"
done

export PATH="$TEMP_DIR/bin:$PATH"
export PI_HARNESS_TEST_MODE=1
export PI_HARNESS_RUNS_DIR="$TEMP_DIR/runs"

ln -s "$ROOT_DIR/pi-harness/bin/pi-harness" "$TEMP_DIR/bin/pi-harness-enlace"

DOCTOR() {
  PI_HARNESS_PLATFORM_OVERRIDE="$1" "$HARNESS" doctor \
    --role backend \
    --workspace "$TEMP_DIR/workspace" \
    --agent-dir "$TEMP_DIR/agente" \
    --json
}

linux_result="$(DOCTOR linux)"
[ "$(jq -r '.backend' <<<"$linux_result")" = "bwrap" ] || FAIL "Linux no seleccionó bwrap"
[ "$(jq -r '.ready' <<<"$linux_result")" = "true" ] || FAIL "doctor de Linux no quedó listo"

linked_result="$(PI_HARNESS_PLATFORM_OVERRIDE=linux "$TEMP_DIR/bin/pi-harness-enlace" doctor \
  --role backend \
  --workspace "$TEMP_DIR/workspace" \
  --agent-dir "$TEMP_DIR/agente" \
  --json)"
[ "$(jq -r '.policy' <<<"$linked_result")" = "$ROOT_DIR/pi-harness/policies/backend.json" ] || \
  FAIL "el enlace simbólico perdió la ubicación real de las políticas"

macos_result="$(DOCTOR macos)"
[ "$(jq -r '.backend' <<<"$macos_result")" = "seatbelt" ] || FAIL "macOS no seleccionó Seatbelt"

windows_result="$(DOCTOR windows)"
[ "$(jq -r '.backend' <<<"$windows_result")" = "appcontainer" ] || FAIL "Windows no seleccionó AppContainer"

if PI_HARNESS_PLATFORM_OVERRIDE=linux "$HARNESS" doctor \
  --role backend \
  --workspace "$TEMP_DIR/workspace" \
  --agent-dir "$TEMP_DIR/agente" \
  --backend seatbelt >/dev/null 2>&1; then
  FAIL "el harness aceptó un backend incompatible con Linux"
fi

PI_HARNESS_PLATFORM_OVERRIDE=linux "$HARNESS" start \
  --role backend \
  --workspace "$TEMP_DIR/workspace" \
  --agent-dir "$TEMP_DIR/agente" \
  --provider openrouter \
  --model cohere/north-mini-code:free \
  --task "Tarea local de prueba" \
  --dry-run >/dev/null

manifest="$(find "$TEMP_DIR/runs" -mindepth 2 -maxdepth 2 -name manifest.json -print -quit)"
[ -n "$manifest" ] || FAIL "el dry-run no generó un manifiesto"
[ "$(jq -r '.engine' "$manifest")" = "pi" ] || FAIL "el manifiesto no registra Pi"
[ "$(jq -r '.sandbox_backend' "$manifest")" = "bwrap" ] || FAIL "el manifiesto no registra bwrap"
[ "$(jq -r '.sandbox_enforced' "$manifest")" = "true" ] || FAIL "el manifiesto no registra aislamiento"
[ "$(jq -r '.status' "$manifest")" = "dry-run" ] || FAIL "el manifiesto no terminó como dry-run"
[ "$(jq -r '.prompt_sha256 | length' "$manifest")" = "64" ] || FAIL "el manifiesto no identifica el prompt"
[ "$(jq -r '.pi.provider' "$manifest")" = "openrouter" ] || FAIL "el manifiesto no registra el proveedor"
[ "$(jq -r '.pi.model' "$manifest")" = "cohere/north-mini-code:free" ] || FAIL "el manifiesto no registra el modelo"
grep -F 'resolver_path="$(readlink -f /etc/resolv.conf' "$ROOT_DIR/pi-harness/bin/pi-harness" >/dev/null || \
  FAIL "el backend Linux no conserva el resolvedor DNS enlazado"
grep -F 'args+=(--bind "$RUN_DIR" "$RUN_DIR")' "$ROOT_DIR/pi-harness/bin/pi-harness" >/dev/null || \
  FAIL "el sandbox no expone el directorio escribible de auditoría"

PI_HARNESS_PLATFORM_OVERRIDE=linux "$HARNESS" start \
  --role backend \
  --workspace "$TEMP_DIR/workspace" \
  --agent-dir "$TEMP_DIR/agente" \
  --task "Tarea simulada con captura de salida"

completed_manifest="$(find "$TEMP_DIR/runs" -mindepth 2 -maxdepth 2 -name manifest.json -print | while IFS= read -r candidate; do
  [ "$(jq -r '.status' "$candidate")" = "completed" ] && { echo "$candidate"; break; }
done)"
[ -n "$completed_manifest" ] || FAIL "la ejecución simulada no terminó correctamente"
completed_run_dir="$(dirname "$completed_manifest")"
[ -f "$completed_run_dir/events.jsonl" ] || FAIL "no se conservó la salida JSONL de Pi"
[ -f "$completed_run_dir/stderr.log" ] || FAIL "no se conservó stderr de Pi"

node --no-warnings --experimental-strip-types "$ROOT_DIR/tests/probar_extension_pi.mjs"

echo "OK: selector multiplataforma, compatibilidad y manifiesto de Pi verificados."
