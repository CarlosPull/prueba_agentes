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
    "repositories":[{"id":"sistema-core","module":"core-autenticacion","kind":"core","path":"/home/agente/core","business_memory":"/home/agente/.local/share/prueba-agentes/business/core.md","aliases":["api","core","autenticación","autenticacion"]}],
    "memory":{"enabled":false}
  },
  "backend-comments": {
    "ip":"192.0.2.12","user":"agente","workspace":"/home/agente/comments","stack":"backend",
    "engine":"pi","dispatch_enabled":true,
    "repositories":[{"id":"modulo-comments","module":"comments","kind":"module","path":"/home/agente/comments","business_memory":"/home/agente/.local/share/prueba-agentes/business/comments.md","aliases":["comments","comentarios"]}],
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

pagos_con_alias_generico="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'Audita la API de pagos e identifica endpoints')"
[ "$(jq '[.targets[] | select(.profile == "backend-pagos")] | length' <<< "$pagos_con_alias_generico")" = "1" ]
[ "$(jq '[.targets[] | select(.profile == "backend-core")] | length' <<< "$pagos_con_alias_generico")" = "0" ]

# Las conjunciones con verbos de acción dividen la oración en sub-requisitos asignados al mismo módulo.
pagos_fragmentado="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'En pagos crea un endpoint Laravel y agrega validación PHP')"
[ "$(jq '[.requirements[] | select(.category == "backend" and .target_profile == "backend-pagos" and .repository == "modulo-pagos")] | length' <<< "$pagos_fragmentado")" = "2" ]

multimodulo="$($ROOT/tools/orquestacion/orquestar.sh --descomponer 'Realiza una auditoría técnica integral de solo lectura y sin modificar archivos sobre los contratos API entre core, pagos y comments. En cada repositorio identifica endpoints y relaciones relevantes.')"
[ "$(jq -r '.execution_policy.read_only' <<< "$multimodulo")" = "true" ]
[ "$(jq '[.targets[].profile] | sort == ["backend-comments","backend-core","backend-pagos"]' <<< "$multimodulo")" = "true" ]
[ "$(jq '[.requirements[] | select(.target_profile != null and (.text | contains("En cada repositorio")))] | length' <<< "$multimodulo")" = "3" ]

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

salida_lectura="$($ROOT/tools/orquestacion/orquestar.sh 'Audita en modo de solo lectura y sin modificar archivos los endpoints Laravel de pagos y core')"
project_dir_lectura="$(printf '%s\n' "$salida_lectura" | sed -n 's/^Proyecto: //p')"
[ "$(find "$project_dir_lectura" -name '*_output.log' -type f | wc -l | tr -d ' ')" = "2" ]
[ "$(grep -l 'MODO_SOLO_LECTURA: true' "$project_dir_lectura"/*_output.log | wc -l | tr -d ' ')" = "2" ]
grep -R -q 'no publiques contratos ni memoria' "$project_dir_lectura"/*_output.log

# El alta de un segundo repositorio conserva su memoria dentro de la VM.
mkdir -p "$TEMP_DIR/proyecto-local" "$TEMP_DIR/bin" "$TEMP_DIR/remoto/home/serveradmin"
cat > "$TEMP_DIR/proyecto-local/composer.json" <<'JSON'
{
  "require": {
    "php": "^8.4",
    "illuminate/support": "^13.0"
  }
}
JSON
cp "$ROOT/tests/fixtures/ssh" "$TEMP_DIR/bin/ssh"
chmod +x "$TEMP_DIR/bin/ssh"
cat > "$TEMP_DIR/vm-alta.json" <<'JSON'
{"backend-modulos":{"ip":"192.0.2.20","user":"serveradmin","workspace":"/home/serveradmin/base","stack":"backend","engine":"pi","dispatch_enabled":true,"repositories":[]}}
JSON
FAKE_REMOTE_ROOT="$TEMP_DIR/remoto" PATH="$TEMP_DIR/bin:$PATH" \
  PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vm-alta.json" \
  PRUEBA_AGENTES_PRIVATE_TECH_MEMORY="$TEMP_DIR/tecnologias-alta.json" \
  "$ROOT/tools/vms/agregar_repositorio_vm.sh" backend-modulos modulo-inventario inventario module \
    "$TEMP_DIR/proyecto-local" /home/serveradmin/modulo-inventario 'inventario,stock' --solo-configurar >/dev/null
jq -e '."backend-modulos".repositories[0] | .id == "modulo-inventario" and .module == "inventario" and (.aliases | index("stock") != null)' "$TEMP_DIR/vm-alta.json" >/dev/null
[ -s "$TEMP_DIR/remoto/home/serveradmin/.local/share/prueba-agentes/business/modulo-inventario.md" ]
jq -e '.repositories."modulo-inventario"
  | (.technologies | index("PHP ^8.4") != null)
    and (.technologies | index("Illuminate ^13.0") != null)
    and (.technologies | index("Composer") != null)
    and .detection.mode == "automatic"
    and (.detection.sources | index("composer.json") != null)' "$TEMP_DIR/tecnologias-alta.json" >/dev/null

# El detector también reconoce un frontend sin registrarlo todavía en una VM.
mkdir -p "$TEMP_DIR/frontend-local"
cat > "$TEMP_DIR/frontend-local/package.json" <<'JSON'
{
  "engines": {"node": ">=24"},
  "packageManager": "pnpm@10.4.0",
  "dependencies": {"vue": "^3.5.0"},
  "devDependencies": {"typescript": "^5.8.0", "vite": "^7.0.0"}
}
JSON
frontend_technology="$($ROOT/tools/vms/detectar_tecnologias_repositorio.sh "$TEMP_DIR/frontend-local" frontend)"
jq -e '(.technologies | index("Node.js >=24") != null)
  and (.technologies | index("Vue ^3.5.0") != null)
  and (.technologies | index("TypeScript ^5.8.0") != null)
  and (.technologies | index("Vite ^7.0.0") != null)
  and (.technologies | index("pnpm 10.4.0") != null)
  and .architecture == "aplicación frontend Vue"' <<< "$frontend_technology" >/dev/null

echo "✓ Enrutamiento exacto, rechazo ambiguo, tecnología privada y paralelismo modular verificados."
