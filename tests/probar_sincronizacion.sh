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
cp "$FIXTURES/mv" "$TEMP_DIR/bin/mv"
cp "$FIXTURES/flock" "$TEMP_DIR/bin/flock"
chmod +x "$TEMP_DIR/bin/ssh" "$TEMP_DIR/bin/mv" "$TEMP_DIR/bin/flock"
export PATH="$TEMP_DIR/bin:$PATH"

# Crear un remoto Git aislado con la misma estructura del orquestador.
fuente_git="$TEMP_DIR/fuente-git"
origen_git="$TEMP_DIR/origen.git"
mkdir -p "$fuente_git/skills/dev-back" "$fuente_git/skills/dev-front"
cp -R "$ROOT/skills/dev-back/." "$fuente_git/skills/dev-back/"
printf '%s\n' "No debe desplegarse en backend" > "$fuente_git/skills/dev-front/SKILL.md"
git -C "$fuente_git" init -q -b sincronizacion_agentes_ssh
git -C "$fuente_git" config user.name "Prueba Agentes"
git -C "$fuente_git" config user.email "pruebas@example.invalid"
git -C "$fuente_git" add .
git -C "$fuente_git" commit -qm "Versión inicial"
git clone -q --bare "$fuente_git" "$origen_git"
git -C "$fuente_git" remote add origin "$origen_git"

agente_remoto="$FAKE_REMOTE_ROOT/home/serveradmin/agentes/backend"
mkdir -p "$agente_remoto"
cp "$ROOT/tools/remotos/actualizar_agente_git.sh" "$agente_remoto/actualizar_desde_git.sh"
chmod +x "$agente_remoto/actualizar_desde_git.sh"
printf '%s\n%s\n%s\n%s\n' "file://$origen_git" "sincronizacion_agentes_ssh" "backend" "skills/dev-back" > "$agente_remoto/git-agent.conf"

runner_remoto="$FAKE_REMOTE_ROOT/home/serveradmin/.local/bin/agent-runner"
mkdir -p "$(dirname "$runner_remoto")" "$FAKE_REMOTE_ROOT/home/serveradmin/laravel-dev"
cp "$FIXTURES/agent-runner" "$runner_remoto"
chmod +x "$runner_remoto"
export FAKE_RUNNER_PROMPT="$TEMP_DIR/prompt-remoto.txt"

salida_primera="$($ROOT/tools/sincronizar_agente.sh backend)"
test -L "$agente_remoto/actual"
test -s "$agente_remoto/actual/SKILL.md"
test -s "$agente_remoto/actual/.agent-version"
test -s "$agente_remoto/actual/.git-commit"
test -d "$agente_remoto/actual/subagentes"
test ! -e "$agente_remoto/actual/skills"
test ! -e "$FAKE_REMOTE_ROOT/home/serveradmin/agentes/frontend"
printf '%s' "$salida_primera" | grep -q "descargado desde Git y activado"

version_primera="$(cat "$agente_remoto/actual/.agent-version")"
salida_segunda="$($ROOT/tools/sincronizar_agente.sh backend)"
version_segunda="$(cat "$agente_remoto/actual/.agent-version")"
test "$version_primera" = "$version_segunda"
printf '%s' "$salida_segunda" | grep -q "ya está actualizado desde Git"

# Publicar un cambio y comprobar que la VM simulada lo obtiene sin rsync.
printf '\nConvención de prueba Git.\n' >> "$fuente_git/skills/dev-back/memory.md"
git -C "$fuente_git" add skills/dev-back/memory.md
git -C "$fuente_git" commit -qm "Actualizar memoria"
git -C "$fuente_git" push -q origin sincronizacion_agentes_ssh

salida_tercera="$($ROOT/tools/sincronizar_agente.sh backend)"
version_tercera="$(cat "$agente_remoto/actual/.agent-version")"
test "$version_primera" != "$version_tercera"
grep -q "Convención de prueba Git" "$agente_remoto/actual/memory.md"
printf '%s' "$salida_tercera" | grep -q "descargado desde Git y activado"

proyecto="$TEMP_DIR/proyecto"
mkdir -p "$proyecto"
salida_despacho="$($ROOT/tools/despachar_vm.sh backend "$proyecto" "Crear un endpoint de salud")"

test "$salida_despacho" = "$proyecto/backend_output.log"
grep -q "VERSION_AGENTE: $version_tercera" "$proyecto/backend_output.log"
grep -q "EJECUCIÓN_REMOTA_SIMULADA: OK" "$proyecto/backend_output.log"
grep -q "# Skill: Dev Backend Specialist" "$FAKE_RUNNER_PROMPT"
grep -q "# Subagente: Analista de Dominio Backend" "$FAKE_RUNNER_PROMPT"
grep -q "Crear un endpoint de salud" "$FAKE_RUNNER_PROMPT"

echo "✓ Pull Git, actualización atómica, aislamiento y despacho remoto verificados."
