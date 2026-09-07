#!/usr/bin/env bash
# Arranque local del servidor central. Las VMs de módulos se provisionan aparte.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
private="$ROOT/.private/plataforma"
command -v podman >/dev/null || { echo 'Instala Podman.' >&2; exit 1; }
mkdir -p "$private"
chmod 700 "$private"
if [ ! -e "$private/postgres.env" ] && [ ! -e "$private/api.env" ]; then
  password="$(openssl rand -hex 32)"
  app_password="$(openssl rand -hex 32)"
  app_origin="${APP_ORIGIN:-http://127.0.0.1:3100}"
  printf 'POSTGRES_DB=orquestador\nPOSTGRES_USER=orquestador\nPOSTGRES_PASSWORD=%s\n' "$password" > "$private/postgres.env"
  printf 'DATABASE_URL=postgresql://orquestador:%s@127.0.0.1:5432/orquestador\n' "$password" > "$private/migration.env"
  printf 'DATABASE_URL=postgresql://orquestador_app:%s@127.0.0.1:5432/orquestador\nAPP_ORIGIN=%s\n' "$app_password" "$app_origin" > "$private/api.env"
fi
[ -s "$private/postgres.env" ] && [ -s "$private/api.env" ] && [ -s "$private/migration.env" ] || { echo 'Configuración privada incompleta; revisa los archivos de base, migraciones y API.' >&2; exit 1; }
chmod 600 "$private"/*.env
podman build -t localhost/orquestador-plataforma:0.1 -f "$ROOT/plataforma/Containerfile" "$ROOT"
podman pod exists orquestador-plataforma || podman pod create --name orquestador-plataforma --publish 3100:3100 >/dev/null
podman volume exists orquestador-postgres || podman volume create orquestador-postgres >/dev/null
if ! podman container exists orquestador-db; then
  podman run -d --name orquestador-db --pod orquestador-plataforma --env-file "$private/postgres.env" \
    --volume orquestador-postgres:/var/lib/postgresql/data docker.io/library/postgres:17-alpine >/dev/null
else
  podman start orquestador-db >/dev/null
fi
ready=0
for attempt in {1..30}; do
  if podman exec orquestador-db pg_isready -U orquestador >/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo 'PostgreSQL no inició.' >&2; exit 1; }
podman run --rm --pod orquestador-plataforma --env-file "$private/migration.env" localhost/orquestador-plataforma:0.1 node dist/cli.js migrate
app_password="$(sed -n 's#^DATABASE_URL=postgresql://orquestador_app:\([a-f0-9]*\)@.*#\1#p' "$private/api.env")"
[[ "$app_password" =~ ^[a-f0-9]{64}$ ]] || { echo 'La API debe usar el rol orquestador_app con credencial propia.' >&2; exit 1; }
podman exec -i orquestador-db psql -U orquestador -d orquestador -v ON_ERROR_STOP=1 >/dev/null <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='orquestador_app') THEN
    CREATE ROLE orquestador_app LOGIN;
  END IF;
END \$\$;
ALTER ROLE orquestador_app PASSWORD '$app_password';
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE orquestador TO orquestador_app;
GRANT USAGE ON SCHEMA public TO orquestador_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO orquestador_app;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO orquestador_app;
REVOKE ALL ON schema_migrations FROM orquestador_app;
SQL
unset password app_password
# Crear llaves/volúmenes e iniciar trabajadores después de aplicar migraciones.
bash "$ROOT/plataforma/bin/servicios_trabajadores.sh"
previous=''
if podman container exists orquestador-api; then previous="$(podman inspect --format '{{.Image}}' orquestador-api)"; fi
start_api() {
  podman run --replace -d --name orquestador-api --pod orquestador-plataforma --env-file "$private/api.env" \
    --volume orquestador-public:/etc/orquestador:ro \
    --read-only --cap-drop=ALL --security-opt=no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    "$1" >/dev/null
}
start_api localhost/orquestador-plataforma:0.1
ready=0
for attempt in {1..20}; do
  if podman exec orquestador-api node -e 'fetch("http://127.0.0.1:3100/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  [ -z "$previous" ] || start_api "$previous"
  echo 'La nueva API no respondió. Se intentó restaurar la imagen anterior si existía.' >&2
  exit 1
fi
echo 'Plataforma disponible en http://127.0.0.1:3100. Para crear el administrador inicial usa plataforma/bin/crear_admin.sh.'
