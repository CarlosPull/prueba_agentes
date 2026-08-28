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
PROBAR_ROL qa "Crea un plan de pruebas E2E con Playwright"
PROBAR_ROL security "Realiza una auditoría de seguridad OWASP"

if "$ORQUESTAR" --clasificar "Actualiza el inicio de sesión" >/dev/null 2>&1; then
  echo "FALLO: una tarea sin señales de dominio no debe clasificarse automáticamente." >&2
  exit 1
fi
echo "✓ ambigua: se rechazó una tarea sin señales suficientes"

if "$ORQUESTAR" --clasificar "Crea un endpoint y un componente Vue" >/dev/null 2>&1; then
  echo "FALLO: una mezcla no declarada no debe clasificarse automáticamente." >&2
  exit 1
fi
echo "✓ mixta: se rechazó una tarea que no declara Full-Stack"

echo "Todas las pruebas de clasificación pasaron."
