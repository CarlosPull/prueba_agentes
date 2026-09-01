#!/usr/bin/env bash
# Despliega el Gateway como servicio systemd en un servidor central existente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-}"; PKI_DIR="${2:-}"; CLIENTS_FILE="${3:-}"
[ -n "$TARGET" ] && [ -n "$PKI_DIR" ] && [ -n "$CLIENTS_FILE" ] || {
  echo "Uso: COGNEE_BASE_URL=... ./tools/provisionar_memory_gateway.sh usuario@ip <pki-dir> <clients.json>" >&2
  exit 1
}
[[ "$TARGET" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:-]+$ ]] || { echo "Error: destino SSH no válido." >&2; exit 1; }
[ -n "${COGNEE_BASE_URL:-}" ] || { echo "Error: falta COGNEE_BASE_URL." >&2; exit 1; }
for file in "$PKI_DIR/server.key" "$PKI_DIR/server.crt" "$PKI_DIR/ca.crt" "$CLIENTS_FILE"; do
  [ -s "$file" ] || { echo "Error: falta $file" >&2; exit 1; }
done
for command in ssh rsync scp jq; do command -v "$command" >/dev/null || { echo "Error: falta $command." >&2; exit 1; }; done
jq -e '.version == 1 and (.clients | type == "object")' "$CLIENTS_FILE" >/dev/null || { echo "Error: clients.json inválido." >&2; exit 1; }

temporary="$(mktemp -d "${TMPDIR:-/tmp}/memory-gateway-deploy.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
chmod 0700 "$temporary"
printf '%s' "${COGNEE_API_KEY:-}" > "$temporary/cognee-api-key"
printf '%s' "${COGNEE_BEARER_TOKEN:-}" > "$temporary/cognee-bearer-token"
chmod 0600 "$temporary/cognee-api-key" "$temporary/cognee-bearer-token"
sed "s|^COGNEE_BASE_URL=.*|COGNEE_BASE_URL=$COGNEE_BASE_URL|" \
  "$ROOT/memory-gateway/config/gateway.env.example" > "$temporary/gateway.env"
chmod 0600 "$temporary/gateway.env"

remote_stage="/tmp/prueba-agentes-memory-gateway-deploy"
echo "🔐 Validando sudo y Node 24 en $TARGET..."
ssh -tt "$TARGET" "sudo -v && test \"\$(/usr/bin/node -p 'Number(process.versions.node.split(\".\")[0]) >= 24')\" = true" || {
  echo "Error: instala Node 24 como /usr/bin/node en el servidor Gateway." >&2; exit 1;
}
ssh "$TARGET" "rm -rf '$remote_stage' && install -d -m 0700 '$remote_stage/code' '$remote_stage/config'"
rsync -az --delete "$ROOT/memory-gateway/bin" "$ROOT/memory-gateway/lib" "$TARGET:$remote_stage/code/"
scp -q "$PKI_DIR/server.key" "$PKI_DIR/server.crt" "$PKI_DIR/ca.crt" "$CLIENTS_FILE" \
  "$temporary/gateway.env" "$temporary/cognee-api-key" "$temporary/cognee-bearer-token" "$ROOT/memory-gateway/systemd/memory-gateway.service" \
  "$TARGET:$remote_stage/config/"

echo "📦 Instalando servicio central..."
ssh -tt "$TARGET" "sudo sh -eu -c '
  id memory-gateway >/dev/null 2>&1 || useradd --system --home /var/lib/memory-gateway --shell /usr/sbin/nologin memory-gateway
  install -d -o memory-gateway -g memory-gateway -m 0750 /var/lib/memory-gateway /var/lib/memory-gateway/openapi
  install -d -o root -g memory-gateway -m 0750 /etc/memory-gateway
  rm -rf /opt/prueba-agentes-memory-gateway.nuevo
  install -d -o root -g root -m 0755 /opt/prueba-agentes-memory-gateway.nuevo
  cp -R $remote_stage/code/bin $remote_stage/code/lib /opt/prueba-agentes-memory-gateway.nuevo/
  chmod 0755 /opt/prueba-agentes-memory-gateway.nuevo/bin/memory-gateway.mjs
  rm -rf /opt/prueba-agentes-memory-gateway
  mv /opt/prueba-agentes-memory-gateway.nuevo /opt/prueba-agentes-memory-gateway
  install -o root -g memory-gateway -m 0640 $remote_stage/config/server.key /etc/memory-gateway/server.key
  install -o root -g memory-gateway -m 0640 $remote_stage/config/server.crt /etc/memory-gateway/server.crt
  install -o root -g memory-gateway -m 0640 $remote_stage/config/ca.crt /etc/memory-gateway/ca.crt
  install -o root -g memory-gateway -m 0640 $remote_stage/config/$(basename "$CLIENTS_FILE") /etc/memory-gateway/clients.json
  install -o root -g memory-gateway -m 0640 $remote_stage/config/gateway.env /etc/memory-gateway/gateway.env
  install -o root -g memory-gateway -m 0640 $remote_stage/config/cognee-api-key /etc/memory-gateway/cognee-api-key
  install -o root -g memory-gateway -m 0640 $remote_stage/config/cognee-bearer-token /etc/memory-gateway/cognee-bearer-token
  install -o root -g root -m 0644 $remote_stage/config/memory-gateway.service /etc/systemd/system/memory-gateway.service
  rm -rf $remote_stage
  systemctl daemon-reload
  systemctl enable --now memory-gateway
  systemctl --no-pager --full status memory-gateway
'"
echo "✅ Memory Gateway desplegado en $TARGET."
