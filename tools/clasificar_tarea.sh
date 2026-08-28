#!/usr/bin/env bash
# Clasifica una solicitud sin ejecutar agentes ni modificar repositorios remotos.
set -euo pipefail

TAREA="${1:-}"

if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/clasificar_tarea.sh \"Tarea\"" >&2
  exit 1
fi

TAREA_LOWER="$(printf '%s' "$TAREA" | tr '[:upper:]' '[:lower:]')"

COINCIDE() {
  printf '%s\n' "$TAREA_LOWER" | grep -Eiq "$1"
}

# Una ejecución múltiple solo se considera explícita cuando el usuario nombra
# Full-Stack o solicita literalmente ambos dominios.
FULLSTACK_RE='full[ -]?stack|back[ -]?end[[:space:]]*(y|e|and|\+)[[:space:]]*front[ -]?end|front[ -]?end[[:space:]]*(y|e|and|\+)[[:space:]]*back[ -]?end|laravel[[:space:]]*(y|e|and|\+)[[:space:]]*vue|vue[[:space:]]*(y|e|and|\+)[[:space:]]*laravel'
BACKEND_RE='(^|[^[:alnum:]_])(backend|back-end|laravel|php|artisan|eloquent|composer|controlador(es)?|controller(s)?|endpoint(s)?|migraci[oó]n(es)?|migration(s)?|base(s)? de datos|database|sql|middleware|routes/api|app/models|app/http|api)([^[:alnum:]_]|$)'
FRONTEND_RE='(^|[^[:alnum:]_])(frontend|front-end|vue|typescript|vite|tailwind|pinia|componente(s)?|component(s)?|interfaz|ui|pantalla(s)?|vista(s)?|css|html|vitest|src/views|src/components|\.vue)([^[:alnum:]_]|$)'
QA_RE='(^|[^[:alnum:]_])(qa|quality assurance|playwright|selenium|cypress|e2e|end-to-end|plan de pruebas|casos? de prueba)([^[:alnum:]_]|$)'
SECURITY_RE='(^|[^[:alnum:]_])(seguridad|security|vulnerabilidad(es)?|owasp|pentest|auditor[ií]a de seguridad|inyecci[oó]n sql|xss|csrf)([^[:alnum:]_]|$)'

if COINCIDE "$FULLSTACK_RE"; then
  printf '%s\n' "fullstack"
  exit 0
fi

backend=0
frontend=0
qa=0
security=0
COINCIDE "$BACKEND_RE" && backend=1
COINCIDE "$FRONTEND_RE" && frontend=1
COINCIDE "$QA_RE" && qa=1
COINCIDE "$SECURITY_RE" && security=1

total=$((backend + frontend + qa + security))

if [ "$total" -eq 1 ]; then
  [ "$backend" -eq 1 ] && printf '%s\n' "backend"
  [ "$frontend" -eq 1 ] && printf '%s\n' "frontend"
  [ "$qa" -eq 1 ] && printf '%s\n' "qa"
  [ "$security" -eq 1 ] && printf '%s\n' "security"
  exit 0
fi

if [ "$total" -eq 0 ]; then
  echo "CLASIFICACION_AMBIGUA: no se encontraron señales suficientes de backend, frontend, QA o seguridad." >&2
else
  echo "CLASIFICACION_AMBIGUA: la solicitud mezcla dominios sin declarar explícitamente una tarea Full-Stack." >&2
fi
exit 2
