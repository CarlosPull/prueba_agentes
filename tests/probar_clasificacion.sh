#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORQUESTAR="$ROOT/tools/orquestar.sh"

PROBAR_ROL() {
  local esperado="$1"
  local tarea="$2"
  local obtenido
  obtenido="$($ORQUESTAR --clasificar "$tarea")"
  if [ "$obtenido" != "$esperado" ]; then
    echo "FALLO: se esperaba '$esperado' y se obtuvo '$obtenido' para: $tarea" >&2
    exit 1
  fi
  echo "✓ $esperado: $tarea"
}

PROBAR_ROL backend "Crea un endpoint Laravel con un controlador y una migración"
PROBAR_ROL backend "Ejecuta php artisan test para la API"
PROBAR_ROL frontend "Crea un componente Vue con TypeScript"
PROBAR_ROL frontend "Modifica la interfaz y agrega una prueba con Vitest"
PROBAR_ROL fullstack "Implementa una solución full-stack para iniciar sesión"
PROBAR_ROL fullstack "Crea un endpoint y un componente Vue"
PROBAR_ROL fullstack "Necesito un inicio de sesión con un formulario de correo y contraseña"
PROBAR_ROL qa "Crea un plan de pruebas E2E con Playwright"
PROBAR_ROL security "Realiza una auditoría de seguridad OWASP"

if "$ORQUESTAR" --clasificar "Actualiza el flujo principal" >/dev/null 2>&1; then
  echo "FALLO: una tarea sin señales de dominio no debe clasificarse automáticamente." >&2
  exit 1
fi
echo "✓ ambigua: se rechazó una tarea sin señales suficientes"

descomposicion="$($ORQUESTAR --descomponer \
  "Crea una migración Laravel para perfiles; implementa una pantalla Vue para editarlos; agrega mensajes claros")"

[ "$(jq -r '.version' <<<"$descomposicion")" = "1" ] || {
  echo "FALLO: la descomposición no tiene una versión reconocible." >&2
  exit 1
}
[ "$(jq '[.requirements[] | select(.category == "backend")] | length' <<<"$descomposicion")" = "1" ] || {
  echo "FALLO: no se generó el requisito backend esperado." >&2
  exit 1
}
[ "$(jq '[.requirements[] | select(.category == "frontend")] | length' <<<"$descomposicion")" = "1" ] || {
  echo "FALLO: no se generó el requisito frontend esperado." >&2
  exit 1
}
[ "$(jq '[.requirements[] | select(.category == "general")] | length' <<<"$descomposicion")" = "1" ] || {
  echo "FALLO: no se conservó el requisito general compartido." >&2
  exit 1
}
[ "$(jq -r '.requirements[] | select(.category == "backend") | .text' <<<"$descomposicion")" = \
  "Crea una migración Laravel para perfiles" ] || {
  echo "FALLO: se alteró el texto del requisito backend." >&2
  exit 1
}
echo "✓ descomposición: backend, frontend y requisito general identificados"

echo "Todas las pruebas de clasificación pasaron."
