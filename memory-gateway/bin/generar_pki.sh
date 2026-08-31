#!/usr/bin/env bash
# Genera una CA privada, certificado del Gateway e identidades mTLS por VM.
set -euo pipefail

OUTPUT_DIR="${1:-}"
GATEWAY_HOST="${2:-}"
shift "$([ "$#" -ge 2 ] && echo 2 || echo 0)"
[ -n "$OUTPUT_DIR" ] && [ -n "$GATEWAY_HOST" ] && [ "$#" -gt 0 ] || {
  echo "Uso: ./memory-gateway/bin/generar_pki.sh <directorio> <host-o-ip-gateway> <identidad ...>" >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || { echo "Error: openssl es obligatorio." >&2; exit 1; }
mkdir -p "$OUTPUT_DIR/clients"
chmod 0700 "$OUTPUT_DIR" "$OUTPUT_DIR/clients"

if [ ! -s "$OUTPUT_DIR/ca.key" ]; then
  openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096
  chmod 0600 "$OUTPUT_DIR/ca.key"
  openssl req -x509 -new -sha256 -days 3650 -key "$OUTPUT_DIR/ca.key" \
    -subj '/CN=prueba-agentes-memory-ca' -out "$OUTPUT_DIR/ca.crt"
fi

san="DNS:$GATEWAY_HOST"
[[ "$GATEWAY_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && san="IP:$GATEWAY_HOST"
if [ ! -s "$OUTPUT_DIR/server.key" ]; then
  openssl genrsa -out "$OUTPUT_DIR/server.key" 4096
  chmod 0600 "$OUTPUT_DIR/server.key"
  openssl req -new -key "$OUTPUT_DIR/server.key" -subj "/CN=$GATEWAY_HOST" -out "$OUTPUT_DIR/server.csr"
  openssl x509 -req -sha256 -days 825 -in "$OUTPUT_DIR/server.csr" \
    -CA "$OUTPUT_DIR/ca.crt" -CAkey "$OUTPUT_DIR/ca.key" -CAcreateserial \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san") \
    -out "$OUTPUT_DIR/server.crt"
fi

for identity in "$@"; do
  [[ "$identity" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Error: identidad no válida: $identity" >&2; exit 1; }
  prefix="$OUTPUT_DIR/clients/$identity"
  [ ! -e "$prefix.key" ] || { echo "Error: ya existe la identidad '$identity'; no se sobrescribe." >&2; exit 1; }
  openssl genrsa -out "$prefix.key" 3072
  chmod 0600 "$prefix.key"
  openssl req -new -key "$prefix.key" -subj "/CN=$identity" -out "$prefix.csr"
  openssl x509 -req -sha256 -days 365 -in "$prefix.csr" \
    -CA "$OUTPUT_DIR/ca.crt" -CAkey "$OUTPUT_DIR/ca.key" -CAcreateserial \
    -extfile <(printf 'extendedKeyUsage=clientAuth\n') -out "$prefix.crt"
  rm -f "$prefix.csr"
done
rm -f "$OUTPUT_DIR/server.csr"
echo "✓ PKI mTLS creada en $OUTPUT_DIR. Protege ca.key y no la copies a las VMs."
