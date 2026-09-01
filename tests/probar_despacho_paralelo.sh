#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-despacho-paralelo.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

export PRUEBA_AGENTES_PROJECTS_DIR="$TEMP_DIR/proyectos"
export PRUEBA_AGENTES_DIAGNOSTICO_VMS=true
export PRUEBA_AGENTES_DESPACHADOR="$ROOT/tests/fixtures/despachador-pi-paralelo"
export PRUEBA_PARALELA_EVENTOS="$TEMP_DIR/eventos.log"

inicio="$(date +%s)"
salida="$($ROOT/tools/orquestacion/orquestar.sh \
  "Crea una migración Laravel para perfiles y crea un componente Vue para editar perfiles")"
fin="$(date +%s)"
duracion=$((fin - inicio))

[ "$duracion" -lt 4 ] || {
  echo "FALLO: los dos despachos tardaron ${duracion}s; parecen secuenciales." >&2
  exit 1
}

project_dir="$(printf '%s\n' "$salida" | sed -n 's/^Proyecto: //p')"
[ "$(find "$project_dir" -name '*backend*_output.log' -type f | wc -l | tr -d ' ')" = "1" ]
[ "$(find "$project_dir" -name '*frontend*_output.log' -type f | wc -l | tr -d ' ')" = "1" ]
[ -s "$project_dir/REPORTE_PI.md" ]
[ -s "$project_dir/EVIDENCIA_AGENTES.md" ]

inicio_backend="$(awk '$1=="backend" && $2=="inicio" {print $3}' "$PRUEBA_PARALELA_EVENTOS")"
fin_backend="$(awk '$1=="backend" && $2=="fin" {print $3}' "$PRUEBA_PARALELA_EVENTOS")"
inicio_frontend="$(awk '$1=="frontend" && $2=="inicio" {print $3}' "$PRUEBA_PARALELA_EVENTOS")"
fin_frontend="$(awk '$1=="frontend" && $2=="fin" {print $3}' "$PRUEBA_PARALELA_EVENTOS")"
[ "$inicio_backend" -le "$fin_frontend" ] && [ "$inicio_frontend" -le "$fin_backend" ] || {
  echo "FALLO: los intervalos backend/frontend no se superponen." >&2
  exit 1
}

echo "✓ Backend y frontend se ejecutaron en paralelo y se consolidaron al finalizar."
