#!/usr/bin/env bash
# Script de auto-actualización por Git para el servidor central de la plataforma.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANCH="${1:-implementacion_usuarios}"
LOG_FILE="$ROOT/.private/auto_update_plataforma.log"
mkdir -p "$ROOT/.private"

cd "$ROOT"

# Prevenir ejecuciones concurrentes
LOCK_FILE="$ROOT/.private/auto_update.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi
trap 'flock -u 9' EXIT

# Podman crea procesos persistentes (conmon). No deben heredar el candado
# del actualizador, que pertenece únicamente a esta ejecución de Bash.
podman() {
  command podman "$@" 9>&-
}

if ! git fetch origin "$BRANCH" >> "$LOG_FILE" 2>&1; then
  echo "[$(date -Iseconds)] Error: no se pudo consultar origin/$BRANCH." >> "$LOG_FILE"
  exit 1
fi
LOCAL_HASH="$(git rev-parse HEAD 2>/dev/null || echo 'NONE')"
REMOTE_HASH="$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo 'NONE')"

if [ "$LOCAL_HASH" != "$REMOTE_HASH" ] && [ "$REMOTE_HASH" != "NONE" ]; then
  echo "[$(date -Iseconds)] Nuevos cambios detectados en origin/$BRANCH ($REMOTE_HASH). Actualizando..." >> "$LOG_FILE"
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
  git reset --hard "origin/$BRANCH" >> "$LOG_FILE" 2>&1

  echo "[$(date -Iseconds)] Reconstruyendo imagen localhost/orquestador-plataforma:0.1..." >> "$LOG_FILE"
  podman build -t localhost/orquestador-plataforma:0.1 -f "$ROOT/plataforma/Containerfile" "$ROOT" >> "$LOG_FILE" 2>&1

  echo "[$(date -Iseconds)] Reiniciando contenedores de la plataforma..." >> "$LOG_FILE"
  podman stop orquestador-api orquestador-trabajador orquestador-preparacion 2>/dev/null || true
  podman rm -f orquestador-api orquestador-trabajador orquestador-preparacion 2>/dev/null || true

  podman run -d --name orquestador-api --pod orquestador-plataforma \
    -v "$ROOT/config:/srv/orquestador/config:rw" \
    -e DATABASE_URL='postgres://orquestador:orquestador123@localhost:5432/orquestador' \
    -e ORQUESTADOR_ROOT='/app' -e HOST='0.0.0.0' -e PORT='3100' \
    localhost/orquestador-plataforma:0.1 node dist/server.js >> "$LOG_FILE" 2>&1

  podman run -d --name orquestador-trabajador --pod orquestador-plataforma \
    -v "$ROOT/config:/srv/orquestador/config:rw" \
    -e DATABASE_URL='postgres://orquestador:orquestador123@localhost:5432/orquestador' \
    -e ORQUESTADOR_ROOT='/app' \
    localhost/orquestador-plataforma:0.1 node dist/worker-main.js >> "$LOG_FILE" 2>&1

  podman run -d --name orquestador-preparacion --pod orquestador-plataforma \
    -v "$ROOT/config:/srv/orquestador/config:rw" \
    -e DATABASE_URL='postgres://orquestador:orquestador123@localhost:5432/orquestador' \
    -e ORQUESTADOR_ROOT='/app' \
    localhost/orquestador-plataforma:0.1 node dist/provision-main.js >> "$LOG_FILE" 2>&1

  echo "[$(date -Iseconds)] Actualización de la plataforma completada exitosamente." >> "$LOG_FILE"
fi
