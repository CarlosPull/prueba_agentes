#!/usr/bin/env bash
# Verifica el script de actualización de memoria de negocio (actualizar_memoria_negocio_vm.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export FAKE_REMOTE_ROOT="$TEMP_DIR/remoto"
export HOME="$TEMP_DIR/home"
mkdir -p "$HOME" "$TEMP_DIR/bin"

cp "$FIXTURES/ssh" "$TEMP_DIR/bin/ssh"
chmod +x "$TEMP_DIR/bin/ssh"
export PATH="$TEMP_DIR/bin:$PATH"

export PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vms.json"

cat <<'EOF' > "$PRUEBA_AGENTES_VMS_CONF"
{
  "backend-test": {
    "ip": "192.168.50.193",
    "user": "serveradmin",
    "workspace": "/home/serveradmin/api-monolitic",
    "stack": "backend",
    "repositories": [
      {
        "id": "api-monolitic",
        "module": "core",
        "kind": "core",
        "path": "/home/serveradmin/api-monolitic",
        "business_memory": "/home/serveradmin/.local/share/prueba-agentes/business/api-monolitic.md",
        "aliases": ["core", "api"]
      }
    ]
  }
}
EOF

memory_path_remota="$FAKE_REMOTE_ROOT/home/serveradmin/.local/share/prueba-agentes/business/api-monolitic.md"

# 1. Prueba por tubería STDIN
echo "# Reglas de negocio desde STDIN" | "$ROOT/tools/vms/actualizar_memoria_negocio_vm.sh" "backend-test" "api-monolitic"
test -f "$memory_path_remota"
test "$(cat "$memory_path_remota")" = "# Reglas de negocio desde STDIN"

# 2. Prueba enviando archivo local como argumento
archivo_local="$TEMP_DIR/nueva_memoria.md"
printf '# Memoria desde archivo local\n- Regla 1: SSL obligatorio\n' > "$archivo_local"

"$ROOT/tools/vms/actualizar_memoria_negocio_vm.sh" "backend-test" "api-monolitic" "$archivo_local"
test "$(cat "$memory_path_remota")" = "$(cat "$archivo_local")"

# 3. Prueba enviando texto directo como argumento
"$ROOT/tools/vms/actualizar_memoria_negocio_vm.sh" "backend-test" "api-monolitic" "# Regla directa"
test "$(cat "$memory_path_remota")" = "# Regla directa"

# 4. Prueba con flag --anexar (append)
"$ROOT/tools/vms/actualizar_memoria_negocio_vm.sh" --anexar "backend-test" "api-monolitic" "- Regla 2: Autenticación requerida"
grep -q "Regla directa" "$memory_path_remota"
grep -q "Regla 2" "$memory_path_remota"

# 5. Verificación de manejo de errores en perfil no existente
if "$ROOT/tools/vms/actualizar_memoria_negocio_vm.sh" "perfil-inexistente" "api-monolitic" "test" 2>/dev/null; then
  echo "Error: Debería haber fallado para un perfil inexistente." >&2
  exit 1
fi

echo "✓ Pruebas de actualizar_memoria_negocio_vm.sh completadas exitosamente."
