#!/usr/bin/env bash
# Instala Node.js, pi (pi-coding-agent) y Podman de forma global (para
# cualquier usuario del sistema, no solo el que provisiona) dentro de una VM
# Ubuntu/Debian. Complementa a instalar_paquetes_backend.sh (PHP+Composer).
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

node_version="${1:-}"
pi_version="${2:-}"

if [[ ! "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: node_version no válido: '$node_version'." >&2
  exit 1
fi
if [[ ! "$pi_version" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  echo "Error: pi_version no válido: '$pi_version'." >&2
  exit 1
fi

node_major="${node_version%%.*}"

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Node.js del sistema (NodeSource): queda en /usr/bin, visible para
# cualquier usuario sin depender de un ~/.nvm por-usuario.
curl -fsSL "https://deb.nodesource.com/setup_${node_major}.x" | sudo -E bash -
sudo apt-get install -y nodejs

# Al instalar con privilegios de administrador, "npm install -g" usa el
# prefix global del sistema (no el home de un usuario), quedando disponible
# para cualquier cuenta que inicie sesión en esta VM.
sudo npm install -g "@earendil-works/pi-coding-agent@$pi_version"

# Mismos paquetes de Podman rootless que usa plataforma/remoto/preparar.sh.
sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs dbus-user-session util-linux

echo "✓ Node $(node -v), npm $(npm -v), pi $(pi --version 2>/dev/null | head -n 1), Podman $(podman --version) instalados globalmente."
