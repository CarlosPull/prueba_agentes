#!/usr/bin/env bash
# Verifica que tools/crear_agente.sh genere agentes válidos.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/crear_agente.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-crear-agente.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

bash -n "$SCRIPT"

# Crear en un directorio temporal simulando skills/
mkdir -p "$TEMP_DIR/root/skills"
cp -r "$ROOT/tools" "$TEMP_DIR/root/"
chmod +x "$TEMP_DIR/root/tools/crear_agente.sh" "$TEMP_DIR/root/tools/agentes/crear_agente.sh"

(
  cd "$TEMP_DIR/root"
  ./tools/crear_agente.sh dev-sec-test "Especialista en Seguridad de Prueba" "Auditar vulnerabilidades de seguridad" "pi-harness,snyk" >/dev/null
)

[ -f "$TEMP_DIR/root/skills/dev-sec-test/SKILL.md" ] || { echo "FALLO: no se creó SKILL.md" >&2; exit 1; }
[ -f "$TEMP_DIR/root/skills/dev-sec-test/subagentes/analista.md" ] || { echo "FALLO: no se creó analista.md" >&2; exit 1; }
[ -f "$TEMP_DIR/root/skills/dev-sec-test/subagentes/generador-codigo.md" ] || { echo "FALLO: no se creó generador-codigo.md" >&2; exit 1; }
[ -f "$TEMP_DIR/root/skills/dev-sec-test/subagentes/qa.md" ] || { echo "FALLO: no se creó qa.md" >&2; exit 1; }
[ -f "$TEMP_DIR/root/skills/dev-sec-test/subagentes/documentador.md" ] || { echo "FALLO: no se creó documentador.md" >&2; exit 1; }

grep -F 'name: dev-sec-test' "$TEMP_DIR/root/skills/dev-sec-test/SKILL.md" >/dev/null
grep -F 'version: 1.0.0' "$TEMP_DIR/root/skills/dev-sec-test/SKILL.md" >/dev/null
grep -F '  - snyk' "$TEMP_DIR/root/skills/dev-sec-test/SKILL.md" >/dev/null

echo "✓ Script de creación de agentes verificado correctamente."
