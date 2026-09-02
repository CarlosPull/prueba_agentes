#!/usr/bin/env bash
# Sincroniza o instala los certificados mTLS del Memory Gateway en las VMs remotas.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="$ROOT/config/vms.json"
PKI_DIR="$ROOT/.private/memory-gateway-pki"

TARGET_PROFILE="${1:-}"

[ -f "$VMS_CONF" ] || { echo "Error: no existe $VMS_CONF" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "Error: ssh es obligatorio." >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "Error: scp es obligatorio." >&2; exit 1; }

# 1. Verificar o generar PKI local
if [ ! -s "$PKI_DIR/ca.crt" ] || [ ! -s "$PKI_DIR/ca.key" ]; then
  echo "🔑 Generando PKI mTLS local en $PKI_DIR..."
  "$ROOT/memory-gateway/bin/generar_pki.sh" "$PKI_DIR" "127.0.0.1" \
    backend-comments backend-posts backend frontend orchestrator-analyst memory-admin
fi

# Lista de perfiles a procesar
if [ -n "$TARGET_PROFILE" ]; then
  profiles=("$TARGET_PROFILE")
else
  profiles=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    profiles+=("$line")
  done < <(jq -r 'to_entries[] | select(.value.engine == "pi" and (.value.dispatch_enabled // true)) | .key' "$VMS_CONF")
fi

[ "${#profiles[@]}" -gt 0 ] || { echo "No hay perfiles de VM para sincronizar." >&2; exit 0; }

echo "🔐 Sincronizando credenciales mTLS con las VMs..."

for profile in "${profiles[@]}"; do
  exists="$(jq -r --arg p "$profile" '.[$p] // empty' "$VMS_CONF")"
  [ -n "$exists" ] || { echo "Error: el perfil '$profile' no existe en vms.json." >&2; exit 1; }

  ip="$(jq -r --arg p "$profile" '.[$p].ip' "$VMS_CONF")"
  user="$(jq -r --arg p "$profile" '.[$p].user' "$VMS_CONF")"
  stack="$(jq -r --arg p "$profile" '.[$p].stack // "backend"' "$VMS_CONF")"

  [ -n "$ip" ] && [ "$ip" != "null" ] && [ -n "$user" ] && [ "$user" != "null" ] || {
    echo "⚠️ Omitiendo perfil '$profile': falta IP o usuario en vms.json." >&2
    continue
  }

  cert_identity="$profile"
  if [ ! -s "$PKI_DIR/clients/$cert_identity.crt" ] || [ ! -s "$PKI_DIR/clients/$cert_identity.key" ]; then
    cert_identity="$stack"
  fi

  if [ ! -s "$PKI_DIR/clients/$cert_identity.crt" ] || [ ! -s "$PKI_DIR/clients/$cert_identity.key" ]; then
    echo "🔑 Generando certificado mTLS individual para '$profile'..."
    openssl genrsa -out "$PKI_DIR/clients/$profile.key" 3072
    chmod 0600 "$PKI_DIR/clients/$profile.key"
    openssl req -new -key "$PKI_DIR/clients/$profile.key" -subj "/CN=$profile" -out "$PKI_DIR/clients/$profile.csr"
    openssl x509 -req -sha256 -days 365 -in "$PKI_DIR/clients/$profile.csr" \
      -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
      -extfile <(printf 'extendedKeyUsage=clientAuth\n') -out "$PKI_DIR/clients/$profile.crt"
    rm -f "$PKI_DIR/clients/$profile.csr"
    cert_identity="$profile"
  fi

  echo "➡️ Copiando mTLS a VM '$profile' ($user@$ip)..."
  if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$user@$ip" "mkdir -p ~/.config/prueba-agentes/memory-gateway && chmod 700 ~/.config/prueba-agentes/memory-gateway" 2>/dev/null; then
    echo "❌ Error al conectar por SSH a $user@$ip." >&2
    continue
  fi

  scp -q -o ConnectTimeout=5 "$PKI_DIR/clients/$cert_identity.crt" "$user@$ip:~/.config/prueba-agentes/memory-gateway/client.crt"
  scp -q -o ConnectTimeout=5 "$PKI_DIR/clients/$cert_identity.key" "$user@$ip:~/.config/prueba-agentes/memory-gateway/client.key"
  scp -q -o ConnectTimeout=5 "$PKI_DIR/ca.crt" "$user@$ip:~/.config/prueba-agentes/memory-gateway/ca.crt"
  ssh -o ConnectTimeout=5 "$user@$ip" "chmod 600 ~/.config/prueba-agentes/memory-gateway/client.key"

  echo "✓ mTLS configurado OK en '$profile' ($user@$ip)"
done

echo ""
echo "✅ Credenciales mTLS instaladas en todas las VMs."
