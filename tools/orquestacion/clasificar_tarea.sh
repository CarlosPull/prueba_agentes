#!/usr/bin/env bash
# Clasifica una solicitud sin ejecutar agentes ni modificar repositorios remotos.
set -euo pipefail

MODO="resumen"
if [ "${1:-}" = "--categorias" ]; then
  MODO="categorias"
  shift
fi

TAREA="${1:-}"

if [ -z "$TAREA" ]; then
  echo "Uso: ./tools/orquestacion/clasificar_tarea.sh [--categorias] \"Tarea\"" >&2
  exit 1
fi

TAREA_LOWER="$(printf '%s' "$TAREA" | tr '[:upper:]' '[:lower:]')"

COINCIDE() {
  printf '%s\n' "$TAREA_LOWER" | grep -Eiq "$1"
}

# Las señales Full-Stack fuerzan las dos categorías. En modo --categorias se
# imprimen todas las categorías detectadas, una por línea, para que el
# descomponedor pueda clasificar cada requisito de forma independiente.
FULLSTACK_RE='full[ -]?stack|back[ -]?end[[:space:]]*(y|e|and|\+)[[:space:]]*front[ -]?end|front[ -]?end[[:space:]]*(y|e|and|\+)[[:space:]]*back[ -]?end|laravel[[:space:]]*(y|e|and|\+)[[:space:]]*vue|vue[[:space:]]*(y|e|and|\+)[[:space:]]*laravel'
BACKEND_RE='(^|[^[:alnum:]_])(backend|back-end|laravel|php|artisan|eloquent|composer|controlador(es)?|controller(s)?|endpoint(s)?|migraci[oó]n(es)?|migration(s)?|base(s)? de datos|database|sql|middleware|routes/api|app/models|app/http|api|autenticaci[oó]n|inicio de sesi[oó]n|login|registro de usuarios|persistencia|servidor|posts|publicaci[oó]n|publicaciones|comentario|comentarios|comments)([^[:alnum:]_]|$)'
FRONTEND_RE='(^|[^[:alnum:]_])(frontend|front-end|vue|typescript|vite|tailwind|pinia|componente(s)?|component(s)?|interfaz|ui|pantalla(s)?|vista(s)?|formulario(s)?|bot[oó]n(es)?|modal(es)?|men[uú](s)?|navegaci[oó]n|responsive|dise[nñ]o|css|html|vitest|src/views|src/components|\.vue|inicio de sesi[oó]n|login)([^[:alnum:]_]|$)'
QA_RE='(^|[^[:alnum:]_])(qa|quality assurance|playwright|selenium|cypress|e2e|end-to-end|plan de pruebas|casos? de prueba)([^[:alnum:]_]|$)'
SECURITY_RE='(^|[^[:alnum:]_])(seguridad|security|vulnerabilidad(es)?|owasp|pentest|auditor[ií]a de seguridad|inyecci[oó]n sql|xss|csrf)([^[:alnum:]_]|$)'

backend=0
frontend=0
qa=0
security=0
COINCIDE "$FULLSTACK_RE" && { backend=1; frontend=1; }
COINCIDE "$BACKEND_RE" && backend=1
COINCIDE "$FRONTEND_RE" && frontend=1
COINCIDE "$QA_RE" && qa=1
COINCIDE "$SECURITY_RE" && security=1

total=$((backend + frontend + qa + security))

if [ "$MODO" = "categorias" ]; then
  [ "$backend" -eq 1 ] && printf '%s\n' "backend"
  [ "$frontend" -eq 1 ] && printf '%s\n' "frontend"
  [ "$qa" -eq 1 ] && printf '%s\n' "qa"
  [ "$security" -eq 1 ] && printf '%s\n' "security"
  [ "$total" -gt 0 ] && exit 0
  exit 2
fi

if [ "$total" -eq 1 ]; then
  [ "$backend" -eq 1 ] && printf '%s\n' "backend"
  [ "$frontend" -eq 1 ] && printf '%s\n' "frontend"
  [ "$qa" -eq 1 ] && printf '%s\n' "qa"
  [ "$security" -eq 1 ] && printf '%s\n' "security"
  exit 0
fi

if [ "$backend" -eq 1 ] && [ "$frontend" -eq 1 ] && [ "$total" -eq 2 ]; then
  printf '%s\n' "fullstack"
  exit 0
fi

if [ "$total" -eq 0 ]; then
  echo "CLASIFICACION_AMBIGUA: no se encontraron señales suficientes de backend, frontend, QA o seguridad." >&2
else
  echo "CLASIFICACION_AMBIGUA: la solicitud mezcla categorías que no pueden despacharse juntas automáticamente." >&2
fi
exit 2
