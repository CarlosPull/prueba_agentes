#!/usr/bin/env bash
# Divide una solicitud en requisitos pequeños y categoriza cada uno por dominio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLASIFICADOR="$ROOT/tools/orquestacion/clasificar_tarea.sh"
TAREA="${1:-}"

if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/orquestacion/descomponer_requisitos.sh \"Solicitud\"" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para descomponer requisitos." >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/requisitos-orquestador.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
SEGMENTOS="$TMP_DIR/segmentos.txt"
REQUISITOS_NDJSON="$TMP_DIR/requisitos.ndjson"

# Se conservan las palabras originales y se separan únicamente límites fuertes
# de oración. No se dividen las conjunciones "y/e": hacerlo separaba el nombre
# del módulo de su acción y podía perder destinos en solicitudes multimódulo.
# El analista posterior puede expandir una oración hacia varios repositorios.
printf '%s\n' "$TAREA" |
  sed -E \
    -e 's/\r//g' \
    -e 's/[;.!?]+[[:space:]]*/\
/g' \
    -e 's/[[:space:]]+[Aa]dem[aá]s[[:space:]]+/\
/g' \
    -e 's/[[:space:]]+[Tt]ambi[eé]n[[:space:]]+/\
/g' \
    -e 's/[[:space:]]+[Ll]uego[[:space:]]+/\
/g' \
    -e 's/[[:space:]]+[Dd]espu[eé]s[[:space:]]+/\
/g' \
    -e 's/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' |
  sed '/^[[:space:]]*$/d' > "$SEGMENTOS"

[ -s "$SEGMENTOS" ] || {
  echo "DESCOMPOSICION_FALLIDA: la solicitud no contiene requisitos utilizables." >&2
  exit 2
}

indice=0
while IFS= read -r segmento; do
  categorias="$($CLASIFICADOR --categorias "$segmento" 2>/dev/null || true)"
  if [ -z "$categorias" ]; then
    categorias="general"
  fi

  while IFS= read -r categoria; do
    [ -n "$categoria" ] || continue
    indice=$((indice + 1))
    id="$(printf 'REQ-%03d' "$indice")"
    jq -cn \
      --arg id "$id" \
      --arg category "$categoria" \
      --arg text "$segmento" \
      '{id:$id, category:$category, text:$text}' >> "$REQUISITOS_NDJSON"
  done <<EOF
$categorias
EOF
done < "$SEGMENTOS"

jq -s --arg original "$TAREA" '
  {
    version: 1,
    original: $original,
    requirements: .,
    categories: ([.[].category] | unique),
    dispatch_categories: ([.[].category | select(. != "general")] | unique)
  }
' "$REQUISITOS_NDJSON"
