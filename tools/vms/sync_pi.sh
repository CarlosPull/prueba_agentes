#!/usr/bin/env bash
# Copia la sesión local de Pi (Codex) a las VMs donde el usuario actual tiene
# una cuenta registrada en vms.json (users[].name) con acceso de lectura
# (can_read) a algún repositorio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

PI_PROVEEDOR="openai-codex"
AUTH_LOCAL="$HOME/.pi/agent/auth.json"
USUARIO_NOMBRE="${1:-$(whoami)}"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

USO() {
  echo "Uso: ./tools/vms/sync_pi.sh [nombre-de-usuario]" >&2
  echo "  nombre-de-usuario: debe coincidir con 'users[].name' en vms.json." >&2
  echo "                     Por defecto usa el usuario actual de esta Mac (\$(whoami))." >&2
}

VERIFICAR_DEPENDENCIAS() {
  local comando
  for comando in jq ssh scp pi; do
    command -v "$comando" >/dev/null 2>&1 || {
      echo "Error: '$comando' es obligatorio en la Mac." >&2
      exit 1
    }
  done
  [ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }
  if [ -z "$USUARIO_NOMBRE" ]; then
    echo "Error: no se pudo determinar el nombre de usuario." >&2
    USO
    exit 1
  fi
}

VERIFICAR_SESION_LOCAL() {
  local estado
  estado="$(pi auth check --provider "$PI_PROVEEDOR" --json 2>/dev/null | jq -r '.status // "error"')"
  if [ "$estado" != "ready" ]; then
    echo "❌ No hay una sesión activa de Pi con '$PI_PROVEEDOR' en esta Mac." >&2
    echo "   Inicia sesión primero:" >&2
    echo "     pi" >&2
    echo "     /login $PI_PROVEEDOR" >&2
    exit 1
  fi
  [ -s "$AUTH_LOCAL" ] || {
    echo "Error: la sesión aparece activa pero no se encontró '$AUTH_LOCAL'." >&2
    exit 1
  }
  echo "✓ Sesión local de Pi ('$PI_PROVEEDOR') activa."
}

# Busca, en cada VM de vms.json, la entrada de users[] cuyo "name" coincide con
# USUARIO_NOMBRE y devuelve (perfil, ip, nombre, node_version, pi_version) por
# cada repositorio con can_read=true, deduplicado por ip+nombre. node_version y
# pi_version se necesitan para poder instalar "pi" remotamente si hiciera falta.
OBTENER_VMS_CON_ACCESO() {
  jq -r --arg usuario "$USUARIO_NOMBRE" '
    to_entries[]
    | .key as $perfil | .value as $vm
    | ($vm.users // [])[]
    | select((.name // "" | ascii_downcase) == ($usuario | ascii_downcase))
    | .name as $nombre
    | (.repositories // [])[]
    | select((.can_read // false) and ((.engine // "pi") == "pi") and (.dispatch_enabled // true))
    | [$perfil, $vm.ip, $nombre, (.node_version // ""), (.pi_version // "latest")] | @tsv
  ' "$VMS_CONF" | sort -u -t $'\t' -k2,2 -k3,3
}

# Convierte "24.19.0" en "v24.19.0": así se llaman los directorios de nvm
# (mismo criterio que usan probar_vms.sh y despachar_vm.sh).
CALCULAR_DIRECTORIO_NODE() {
  local version="$1"
  [[ "$version" == v* ]] && printf '%s' "$version" || printf 'v%s' "$version"
}

# PATH remoto donde viven node/npm/pi una vez instalados vía nvm.
CALCULAR_PATH_REMOTO() {
  local usuario="$1" directorio_node="$2"
  printf '/home/%s/.nvm/versions/node/%s/bin:/home/%s/.local/bin' "$usuario" "$directorio_node" "$usuario"
}

VERIFICAR_PI_INSTALADO() {
  local ip="$1" usuario="$2" path_remoto="$3"
  ssh "${SSH_OPTS[@]}" "$usuario@$ip" "export PATH=\"$path_remoto:\$PATH\"; command -v pi" >/dev/null 2>&1
}

# Instala "pi" (@earendil-works/pi-coding-agent) en la VM vía npm global,
# siguiendo el mismo paquete y flags que usa tools/remotos/provisionar_vm_pi.sh.
INSTALAR_PI_EN_VM() {
  local perfil="$1" ip="$2" usuario="$3" path_remoto="$4" version_pi="$5"

  if ! ssh "${SSH_OPTS[@]}" "$usuario@$ip" "export PATH=\"$path_remoto:\$PATH\"; command -v npm" >/dev/null 2>&1; then
    echo "❌ '$perfil' ($usuario@$ip): no se encontró 'npm' en esa VM; no se puede instalar pi." >&2
    echo "   Corre primero: ./tools/vms/provisionar_vm_pi.sh <perfil> --con-sudo-interactivo" >&2
    return 1
  fi

  # --prefix apunta al ~/.local del propio usuario: evita depender de permisos
  # de escritura en el prefijo global de npm (p. ej. /usr/lib/node_modules
  # cuando Node se instaló vía apt en vez de nvm, que pertenece a root).
  # ~/.local/bin ya forma parte de path_remoto, así que el binario "pi"
  # resultante se encuentra sin pasos adicionales.
  local prefijo_local="/home/$usuario/.local"
  echo "📦 Instalando pi ('$version_pi') en '$perfil' ($usuario@$ip)..."
  if ! ssh "${SSH_OPTS[@]}" "$usuario@$ip" \
    "export PATH=\"$path_remoto:\$PATH\"; npm install -g --ignore-scripts --prefix \"$prefijo_local\" '@earendil-works/pi-coding-agent@$version_pi'" 2>&1 \
    | sed 's/^/   /'; then
    echo "❌ '$perfil' ($usuario@$ip): falló la instalación de pi." >&2
    return 1
  fi
  echo "✓ pi instalado en '$perfil' ($usuario@$ip)."
  return 0
}

# Confirma acceso SSH a la VM como "usuario" antes de copiar nada.
# SSH responde "Permission denied" tanto si la cuenta no tiene la llave
# autorizada como si la cuenta no existe (no se puede distinguir desde fuera
# sin credenciales alternativas a esa VM), así que ante ese fallo se avisan
# ambas causas posibles y se sugiere el comando exacto para autorizar la llave.
VERIFICAR_ACCESO_VM() {
  local perfil="$1" ip="$2" usuario="$3"
  local salida_ssh

  if salida_ssh="$(ssh "${SSH_OPTS[@]}" "$usuario@$ip" "id -u -- '$usuario'" 2>&1)"; then
    return 0
  fi

  if printf '%s' "$salida_ssh" | grep -qi "Permission denied"; then
    echo "⚠️ Omitiendo '$perfil': no se pudo autenticar como '$usuario' en $ip." >&2
    echo "   Puede deberse a que tu llave SSH aún no está autorizada en esa cuenta," >&2
    echo "   o a que la cuenta todavía no existe en esa VM." >&2
    echo "   Si la cuenta ya existe, autoriza tu llave con:" >&2
    echo "     ./tools/vms/configurar_ssh_vm.sh $usuario@$ip" >&2
  else
    echo "⚠️ Omitiendo '$perfil': no se pudo conectar a $ip (host inaccesible o tiempo agotado)." >&2
  fi
  return 1
}

COPIAR_SESION_A_VM() {
  local perfil="$1" ip="$2" usuario="$3"
  local directorio_remoto="/home/$usuario/.pi/agent"

  [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] && [[ "$usuario" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "⚠️ Omitiendo '$perfil': IP o usuario con formato inseguro." >&2
    return 1
  }

  if ! ssh "${SSH_OPTS[@]}" "$usuario@$ip" "mkdir -p '$directorio_remoto' && chmod 700 '$directorio_remoto'" 2>/dev/null; then
    echo "❌ '$perfil' ($usuario@$ip): no se pudo preparar el directorio remoto." >&2
    return 1
  fi

  if ! scp -q "${SSH_OPTS[@]}" "$AUTH_LOCAL" "$usuario@$ip:$directorio_remoto/auth.json"; then
    echo "❌ '$perfil' ($usuario@$ip): falló la copia de auth.json." >&2
    return 1
  fi

  ssh "${SSH_OPTS[@]}" "$usuario@$ip" "chmod 600 '$directorio_remoto/auth.json'"
  echo "✓ Sesión copiada a '$perfil' ($usuario@$ip)."
  return 0
}

MAIN() {
  VERIFICAR_DEPENDENCIAS
  VERIFICAR_SESION_LOCAL

  echo ""
  echo "🔎 Buscando VMs donde '$USUARIO_NOMBRE' tiene acceso de lectura..."
  local filas
  filas="$(OBTENER_VMS_CON_ACCESO)"

  if [ -z "$filas" ]; then
    echo "ℹ️ No se encontró ninguna VM con un usuario '$USUARIO_NOMBRE' con permiso de lectura en $VMS_CONF."
    exit 0
  fi

  local perfil ip usuario version_node version_pi directorio_node path_remoto
  local total_copiadas=0
  local total_omitidas=0

  # Lee de fd 3, no de stdin: los "ssh"/"scp" de más abajo no redirigen su
  # propio stdin, y si el bucle leyera de fd 0 se comerían las filas
  # restantes de $filas, cortando el bucle tras la primera VM.
  while IFS=$'\t' read -r -u 3 perfil ip usuario version_node version_pi; do
    [ -n "$perfil" ] || continue
    echo ""
    echo "🌐 Perfil '$perfil' ($usuario@$ip)"

    if ! VERIFICAR_ACCESO_VM "$perfil" "$ip" "$usuario"; then
      total_omitidas=$((total_omitidas + 1))
      continue
    fi

    version_node="${version_node:-24.19.0}"
    directorio_node="$(CALCULAR_DIRECTORIO_NODE "$version_node")"
    path_remoto="$(CALCULAR_PATH_REMOTO "$usuario" "$directorio_node")"

    if ! VERIFICAR_PI_INSTALADO "$ip" "$usuario" "$path_remoto"; then
      echo "ℹ️ pi no está disponible en '$perfil' ($usuario@$ip)." >&2
      if ! INSTALAR_PI_EN_VM "$perfil" "$ip" "$usuario" "$path_remoto" "$version_pi"; then
        total_omitidas=$((total_omitidas + 1))
        continue
      fi
    fi

    if COPIAR_SESION_A_VM "$perfil" "$ip" "$usuario"; then
      total_copiadas=$((total_copiadas + 1))
    else
      total_omitidas=$((total_omitidas + 1))
    fi
  done 3<<< "$filas"

  echo ""
  echo "------------------------------------------------------------"
  echo "✅ Sesión distribuida a $total_copiadas VM(s); omitidas: $total_omitidas."
}

MAIN "$@"
