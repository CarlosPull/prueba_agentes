#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export FAKE_REMOTE_ROOT="$TEMP_DIR/remoto"
export HOME="$TEMP_DIR/home"
mkdir -p "$HOME" "$TEMP_DIR/bin"

cp "$FIXTURES/ssh" "$TEMP_DIR/bin/ssh"
cp "$FIXTURES/rsync" "$TEMP_DIR/bin/rsync"
cp "$FIXTURES/mv" "$TEMP_DIR/bin/mv"
chmod +x "$TEMP_DIR/bin/ssh" "$TEMP_DIR/bin/rsync" "$TEMP_DIR/bin/mv"
export PATH="$TEMP_DIR/bin:$PATH"

runner_remoto="$FAKE_REMOTE_ROOT/home/serveradmin/.local/bin/agent-runner"
mkdir -p "$(dirname "$runner_remoto")" "$FAKE_REMOTE_ROOT/home/serveradmin/laravel-dev"
cp "$FIXTURES/agent-runner" "$runner_remoto"
chmod +x "$runner_remoto"
export FAKE_RUNNER_PROMPT="$TEMP_DIR/prompt-remoto.txt"

salida_primera="$($ROOT/tools/sincronizar_agente.sh backend)"
agente_remoto="$FAKE_REMOTE_ROOT/home/serveradmin/agentes/backend"

test -L "$agente_remoto/actual"
test -s "$agente_remoto/actual/SKILL.md"
test -s "$agente_remoto/actual/.agent-version"
test -d "$agente_remoto/actual/subagentes"
test ! -e "$FAKE_REMOTE_ROOT/home/serveradmin/agentes/frontend"
printf '%s' "$salida_primera" | grep -q "actualizado y activado"

version_primera="$(cat "$agente_remoto/actual/.agent-version")"
salida_segunda="$($ROOT/tools/sincronizar_agente.sh backend)"
version_segunda="$(cat "$agente_remoto/actual/.agent-version")"

test "$version_primera" = "$version_segunda"
printf '%s' "$salida_segunda" | grep -q "ya está actualizado"

proyecto="$TEMP_DIR/proyecto"
mkdir -p "$proyecto"
salida_despacho="$($ROOT/tools/despachar_vm.sh backend "$proyecto" "Crear un endpoint de salud")"

test "$salida_despacho" = "$proyecto/backend_output.log"
grep -q "VERSION_AGENTE: $version_primera" "$proyecto/backend_output.log"
grep -q "EJECUCIÓN_REMOTA_SIMULADA: OK" "$proyecto/backend_output.log"
grep -q "# Skill: Dev Backend Specialist" "$FAKE_RUNNER_PROMPT"
grep -q "# Subagente: Analista de Dominio Backend" "$FAKE_RUNNER_PROMPT"
grep -q "RECURSO DEL AGENTE: subagentes/analista.md" "$FAKE_RUNNER_PROMPT"
grep -q "Crear un endpoint de salud" "$FAKE_RUNNER_PROMPT"
grep -q "$agente_remoto/actual" "$FAKE_RUNNER_PROMPT"

echo "✓ Sincronización aislada, activación atómica y despacho remoto verificados."
