#!/usr/bin/env bash
# PostgreSQL efímero exclusivamente para pruebas. Sin servicios Docker ni Compose.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v podman >/dev/null || { echo 'Instala Podman antes de ejecutar las pruebas.' >&2; exit 1; }
name="orquestador-pruebas-$$"
tmp="$(mktemp -d)"
cleanup() { podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
umask 077
password="$(openssl rand -hex 24)"
printf 'POSTGRES_PASSWORD=%s\nPOSTGRES_DB=orquestador_pruebas\n' "$password" > "$tmp/postgres.env"
podman run --detach --name "$name" --env-file "$tmp/postgres.env" \
  --publish 127.0.0.1::5432 --tmpfs /var/lib/postgresql/data:rw docker.io/library/postgres:17-alpine >/dev/null
port="$(podman port "$name" 5432/tcp | sed 's/.*://')"
ready=0
for attempt in {1..30}; do
  if podman exec "$name" pg_isready -U postgres >/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo 'PostgreSQL no inició.' >&2; exit 1; }
cd "$ROOT"
DATABASE_TEST_URL="postgresql://postgres:$password@127.0.0.1:$port/orquestador_pruebas" npm test
