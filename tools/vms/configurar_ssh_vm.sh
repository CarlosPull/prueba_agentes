#!/usr/bin/env bash
# Herramienta para automatizar la configuración de llaves SSH sin contraseña hacia una nueva VM
set -euo pipefail

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Uso: ./tools/vms/configurar_ssh_vm.sh <usuario>@<ip_vm>"
  echo "Ejemplo: ./tools/vms/configurar_ssh_vm.sh serveradmin@192.168.50.100"
  exit 1
fi

# Validar que no haya múltiples símbolos '@' (ej: usuario@o@192.168.50.63)
AT_COUNT=$(echo "$TARGET" | tr -cd '@' | wc -c | tr -d ' ')
if [ "$AT_COUNT" -ne 1 ]; then
  echo "❌ Error: El parámetro '$TARGET' tiene un formato incorrecto (múltiples '@')."
  echo "Uso correcto: ./tools/vms/configurar_ssh_vm.sh serveradmin@192.168.50.63"
  exit 1
fi


KEY_FILE="$HOME/.ssh/id_ed25519"
PUB_KEY_FILE="$KEY_FILE.pub"

# 1. Asegurar que exista una llave SSH en la Mac
if [ ! -f "$KEY_FILE" ]; then
  echo "🔑 Generando nueva llave SSH ED25519 en tu Mac..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY_FILE"
  echo "✓ Llave creada en $KEY_FILE"
fi

echo "🚀 Configurando la conexión SSH hacia $TARGET..."

# 2. Copiar la clave pública hacia la VM remota
if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "$PUB_KEY_FILE" -o StrictHostKeyChecking=no "$TARGET"
else
  PUB_KEY=$(cat "$PUB_KEY_FILE")
  ssh -o StrictHostKeyChecking=no "$TARGET" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUB_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
fi

# 3. Probar la conexión sin contraseña
echo "🔍 Probando conexión sin contraseña..."
if ssh -i "$KEY_FILE" -o ConnectTimeout=5 -o BatchMode=yes "$TARGET" "echo OK" >/dev/null 2>&1; then
  echo "------------------------------------------------------------"
  echo "✅ ¡Conexión SSH sin contraseña configurada con éxito hacia $TARGET!"
  echo "------------------------------------------------------------"
else
  echo "❌ Error al verificar la conexión SSH."
  exit 1
fi
