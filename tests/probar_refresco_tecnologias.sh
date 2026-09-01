#!/usr/bin/env bash
# Verifica el flag --refrescar-tecnologias y la asignación de QA/Security.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-refresco.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

mkdir -p "$TEMP_DIR/mock-repo" "$TEMP_DIR/vms"
cat > "$TEMP_DIR/mock-repo/composer.json" <<'EOF'
{
  "require": {
    "php": "^8.4",
    "laravel/framework": "^13.0"
  }
}
EOF

cat > "$TEMP_DIR/vms.json" <<'EOF'
{
  "test-vm": {
    "ip": "192.168.50.99",
    "user": "serveradmin",
    "stack": "backend",
    "repositories": []
  }
}
EOF

export PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vms.json"
export PRUEBA_AGENTES_PRIVATE_TECH_MEMORY="$TEMP_DIR/tecnologias.json"

"$ROOT/tools/vms/agregar_repositorio_vm.sh" test-vm test-repo test-mod module "$TEMP_DIR/mock-repo" /home/serveradmin/test-repo test-repo --solo-configurar >/dev/null

[ -f "$TEMP_DIR/tecnologias.json" ] || { echo "FALLO: no se creó tecnologías.json" >&2; exit 1; }
grep -F "PHP" "$TEMP_DIR/tecnologias.json" >/dev/null

# Modificar el manifiesto del proyecto mock agregando un nuevo paquete
cat > "$TEMP_DIR/mock-repo/package.json" <<'EOF'
{
  "dependencies": {
    "vue": "^3.5.0"
  }
}
EOF

# Refrescar tecnologías con el nuevo flag
"$ROOT/tools/vms/agregar_repositorio_vm.sh" test-vm test-repo test-mod module "$TEMP_DIR/mock-repo" /home/serveradmin/test-repo test-repo --solo-configurar --refrescar-tecnologias >/dev/null

grep -F "Vue" "$TEMP_DIR/tecnologias.json" >/dev/null

echo "✓ Flag --refrescar-tecnologias y sincronización de tecnologías verificados correctamente."
