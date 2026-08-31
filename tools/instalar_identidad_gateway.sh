#!/usr/bin/env bash
# Instala en una VM su certificado cliente y la CA pública del Gateway.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PROFILE="${1:-}"; PKI_DIR="${2:-}"
[ -n "$PROFILE" ] && [ -n "$PKI_DIR" ] || { echo "Uso: ./tools/instalar_identidad_gateway.sh <perfil> <directorio-pki>" >&2; exit 1; }
ip="$(jq -er --arg p "$PROFILE" '.[$p].ip' "$VMS_CONF")"
user="$(jq -er --arg p "$PROFILE" '.[$p].user' "$VMS_CONF")"
for file in "$PKI_DIR/clients/$PROFILE.key" "$PKI_DIR/clients/$PROFILE.crt" "$PKI_DIR/ca.crt"; do
  [ -s "$file" ] || { echo "Error: falta $file" >&2; exit 1; }
done
target="$user@$ip"; remote_dir="/home/$user/.config/prueba-agentes/memory-gateway"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "install -d -m 0700 '$remote_dir'"
scp -q "$PKI_DIR/clients/$PROFILE.key" "$target:$remote_dir/client.key.nuevo"
scp -q "$PKI_DIR/clients/$PROFILE.crt" "$target:$remote_dir/client.crt.nuevo"
scp -q "$PKI_DIR/ca.crt" "$target:$remote_dir/ca.crt.nuevo"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
  "chmod 0600 '$remote_dir/'*.nuevo && mv '$remote_dir/client.key.nuevo' '$remote_dir/client.key' && mv '$remote_dir/client.crt.nuevo' '$remote_dir/client.crt' && mv '$remote_dir/ca.crt.nuevo' '$remote_dir/ca.crt'"
echo "✓ Identidad mTLS '$PROFILE' instalada en $target."
