#!/usr/bin/env bash
# Crea la estructura completa de un nuevo agente/skill en skills/<nombre>/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOMBRE="${1:-}"
DESCRIPCION="${2:-}"
MISION="${3:-}"
HERRAMIENTAS_CSV="${4:-pi-harness}"

USO() {
  echo "Uso interactivo:   ./tools/agentes/crear_agente.sh" >&2
  echo "Uso no interactivo: ./tools/agentes/crear_agente.sh <nombre> \"Descripción\" \"Misión\" [\"herramientas-csv\"]" >&2
}

# Modo interactivo si no se proporcionan parámetros suficientes
if [ -z "$NOMBRE" ]; then
  echo "🤖 Generador de nuevos Agentes / Skills"
  echo "---------------------------------------"
  read -r -p "Nombre del agente (ej. dev-security, dev-ops): " NOMBRE
  read -r -p "Descripción breve: " DESCRIPCION
  read -r -p "Misión principal del agente: " MISION
  read -r -p "Herramientas (separadas por coma) [pi-harness]: " HERRAMIENTAS_INPUT
  HERRAMIENTAS_CSV="${HERRAMIENTAS_INPUT:-pi-harness}"
fi

[ -n "$NOMBRE" ] && [ -n "$DESCRIPCION" ] && [ -n "$MISION" ] || { USO; exit 1; }

# Validar formato del nombre (letras minúsculas, números y guiones)
[[ "$NOMBRE" =~ ^[a-z0-9-]+$ ]] || {
  echo "Error: el nombre del agente sólo puede contener letras minúsculas, números y guiones (ej: dev-ops)." >&2
  exit 1
}

TARGET_DIR="$ROOT/skills/$NOMBRE"
[ ! -d "$TARGET_DIR" ] || {
  echo "Error: el agente '$NOMBRE' ya existe en '$TARGET_DIR'." >&2
  exit 1
}

mkdir -p "$TARGET_DIR/subagentes"

# Convertir herramientas CSV a lista YAML
HERRAMIENTAS_YAML=""
IFS=',' read -ra HERRAMIENTAS_ARRAY <<< "$HERRAMIENTAS_CSV"
for tool in "${HERRAMIENTAS_ARRAY[@]}"; do
  tool_trimmed="$(echo "$tool" | xargs)"
  if [ -n "$tool_trimmed" ]; then
    HERRAMIENTAS_YAML="${HERRAMIENTAS_YAML}  - ${tool_trimmed}\n"
  fi
done

# 1. Crear SKILL.md principal
cat > "$TARGET_DIR/SKILL.md" <<EOF
---
name: ${NOMBRE}
description: ${DESCRIPCION}
version: 1.0.0
tools:
$(printf "%b" "$HERRAMIENTAS_YAML")---

# Skill: Specialist (\`${NOMBRE}\`)

## Misión

${MISION}

## Skills & Capacidades

- Diseño e implementación especializada para el dominio \`${NOMBRE}\`.
- Validación de estándares y reglas del repositorio.
- Verificación automatizada de cambios.

## Forma de trabajo

1. Analiza los requisitos entrantes y el contexto del proyecto.
2. Aplica patrones modulares mantenibles sin romper otros módulos.
3. Valida la solución mediante pruebas unitarias antes de concluir.

## Subagentes

- \`analista\`: evalúa y valida primero que la tarea pertenezca a este dominio antes de modificar código.
- \`generador-codigo\`: implementa los cambios en el repositorio.
- \`qa\`: inspecciona y prueba el resultado generado.
- \`documentador\`: registra uso, decisiones y cambios realizados.
EOF

# 2. Crear subagente analista.md
cat > "$TARGET_DIR/subagentes/analista.md" <<EOF
# Subagente: Analista de Dominio (\`analista\`)

## Misión

Evaluar los requisitos entrantes antes de cualquier generación de código. Verificar estricta pertenencia al dominio de \`${NOMBRE}\`.

## Reglas de Evaluación Inquebrantables

1. Si la tarea NO pertenece al dominio \`${NOMBRE}\`:
   - Emitir respuesta terminal de rechazo: STATUS: RECHAZADO_FINAL.
2. Si la tarea pertenece al dominio \`${NOMBRE}\`, otorgar pase al subagente \`generador-codigo\`.
EOF

# 3. Crear subagente generador-codigo.md
cat > "$TARGET_DIR/subagentes/generador-codigo.md" <<EOF
# Subagente: generador-codigo

## Misión

Convertir especificaciones aprobadas en código modular, claro y mantenible para el dominio \`${NOMBRE}\`.
EOF

# 4. Crear subagente qa.md
cat > "$TARGET_DIR/subagentes/qa.md" <<EOF
# Subagente: qa

## Misión

Revisar el código generado para el dominio \`${NOMBRE}\`, detectar defectos y comprobar que satisface el requisito sin regresiones.
EOF

# 5. Crear subagente documentador.md
cat > "$TARGET_DIR/subagentes/documentador.md" <<EOF
# Subagente: documentador

## Misión

Documentar de forma breve y precisa los cambios realizados para el dominio \`${NOMBRE}\`.
EOF

# Preparar en Git si se está dentro de un repo Git
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" add "$TARGET_DIR" 2>/dev/null || true
fi

echo "✓ Agente '$NOMBRE' creado exitosamente en: $TARGET_DIR"
echo "  Estructura creada:"
echo "  ├── SKILL.md"
echo "  └── subagentes/"
echo "      ├── analista.md"
echo "      ├── generador-codigo.md"
echo "      ├── qa.md"
echo "      └── documentador.md"
