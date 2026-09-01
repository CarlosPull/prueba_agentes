#!/usr/bin/env bash
# Verifica selección exacta de VM/repositorio y paralelismo entre módulos backend.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-enrutamiento-modular.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

cat > "$TEMP_DIR/vms.json" <<'JSON'
{
  "backend-pagos": {
    "ip":"192.0.2.10","user":"agente","workspace":"/home/agente/pagos","stack":"backend",
    "engine":"pi","dispatch_enabled":true,
    "repositories":[{"id":"modulo-pagos","module":"pagos","kind":"module","path":"/home/agente/pagos","business_memory":"/home/agente/.local/share/prueba-agentes/business/pagos.md","aliases":["pagos","cobros"]}],
    "memory":{"enabled":false}
  },
  "backend-core": {
    "ip":"192.0.2.11","user":"agente","workspace":"/home/agente/core","stack":"backend",
    "engine":"pi","dispatch_enabled":true,
    "repositories":[{"id":"sistema-core","module":"core-autenticacion","kind":"core","path":"/home/agente/core","business_memory":"/home/agente/.local/share/prueba-agentes/business/core.md","aliases":["core","autenticación","autenticacion"]}],
    "memory":{"enabled":false}
  }
}
JSON

cat > "$TEMP_DIR/tecnologias.json" <<'JSON'
{
  "version":1,
  "repositories":{
    "modulo-pagos":{"technologies":["PHP 8.4"],"constraints":["Usar decimal para dinero"]},
    "sistema-core":{"technologies":["PHP 8.4"],"constraints":["No romper contratos del core"]}
  }
}
JSON

export PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vms.json"
export PRUEBA_AGENTES_PRIVATE_TECH_MEMORY="$TEMP_DIR/tecnologias.json"
export PRUEBA_AGENTES_PRIVATE_MEMORY_REQUIRED=1

pagos="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'Crea un endpoint Laravel para procesar pagos')"
[ "$(jq -r '.requirements[0].target_profile + "/" + .requirements[0].repository' <<< "$pagos")" = "backend-pagos/modulo-pagos" ]
[ "$(jq -r '.requirements[0].technology_constraints.technologies[0]' <<< "$pagos")" = "PHP 8.4" ]

# Los fragmentos secundarios heredan el destino explícito del prompt completo;
# el contexto semántico nunca debe superar a una mención directa del usuario.
pagos_fragmentado="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'En pagos crea un endpoint Laravel y agrega validación PHP')"
[ "$(jq '[.requirements[] | select(.category == "backend" and .target_profile == "backend-pagos" and .repository == "modulo-pagos")] | length' <<< "$pagos_fragmentado")" = "2" ]

core="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'Crea un endpoint Laravel en el core de autenticación')"
[ "$(jq -r '.requirements[0].target_profile + "/" + .requirements[0].repository' <<< "$core")" = "backend-core/sistema-core" ]

if "$ROOT/tools/orquestacion/orquestar.sh" --descomponer 'Crea un endpoint Laravel' >"$TEMP_DIR/ambiguo.out" 2>"$TEMP_DIR/ambiguo.err"; then
  echo "FALLO: un requisito backend ambiguo seleccionó una VM arbitrariamente." >&2
  exit 1
fi
grep -q 'ROUTING_AMBIGUO' "$TEMP_DIR/ambiguo.err"

export PRUEBA_AGENTES_PROJECTS_DIR="$TEMP_DIR/proyectos"
export PRUEBA_AGENTES_DIAGNOSTICO_VMS=true
export PRUEBA_AGENTES_DESPACHADOR="$ROOT/tests/fixtures/despachador-pi-paralelo"
export PRUEBA_PARALELA_EVENTOS="$TEMP_DIR/eventos.log"
inicio="$(date +%s)"
salida="$($ROOT/tools/orquestacion/orquestar.sh 'Crea un endpoint Laravel para procesar pagos; crea un endpoint Laravel en el core de autenticación')"
fin="$(date +%s)"
[ "$((fin - inicio))" -lt 4 ] || { echo "FALLO: los módulos backend se ejecutaron secuencialmente." >&2; exit 1; }
project_dir="$(printf '%s\n' "$salida" | sed -n 's/^Proyecto: //p')"
[ "$(find "$project_dir" -name '*_output.log' -type f | wc -l | tr -d ' ')" = "2" ]
grep -R -q 'backend-pagos' "$project_dir"/*_output.log
grep -R -q 'backend-core' "$project_dir"/*_output.log

# El alta de un segundo repositorio conserva su memoria dentro de la VM.
mkdir -p "$TEMP_DIR/proyecto-local" "$TEMP_DIR/bin" "$TEMP_DIR/remoto/home/serveradmin"
cp "$ROOT/tests/fixtures/ssh" "$TEMP_DIR/bin/ssh"
chmod +x "$TEMP_DIR/bin/ssh"
cat > "$TEMP_DIR/vm-alta.json" <<'JSON'
{"backend-modulos":{"ip":"192.0.2.20","user":"serveradmin","workspace":"/home/serveradmin/base","stack":"backend","engine":"pi","dispatch_enabled":true,"repositories":[]}}
JSON
FAKE_REMOTE_ROOT="$TEMP_DIR/remoto" PATH="$TEMP_DIR/bin:$PATH" \
  PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vm-alta.json" \
  "$ROOT/tools/vms/agregar_repositorio_vm.sh" backend-modulos modulo-inventario inventario module \
    "$TEMP_DIR/proyecto-local" /home/serveradmin/modulo-inventario 'inventario,stock' --solo-configurar >/dev/null
jq -e '."backend-modulos".repositories[0] | .id == "modulo-inventario" and .module == "inventario" and (.aliases | index("stock") != null)' "$TEMP_DIR/vm-alta.json" >/dev/null
[ -s "$TEMP_DIR/remoto/home/serveradmin/.local/share/prueba-agentes/business/modulo-inventario.md" ]

echo "✓ Enrutamiento exacto, rechazo ambiguo, tecnología privada y paralelismo modular verificados."
