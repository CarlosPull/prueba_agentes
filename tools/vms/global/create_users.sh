#!/usr/bin/env bash
# Crea los mismos usuarios de sistema (sin sudo, con acceso SSH por la llave
# compartida) en TODAS las VMs registradas en vms.json. Se conecta como la
# cuenta con permisos sudo (serveradmin) y usa la misma llave que instala
# tools/vms/sync_ssh.sh, así los usuarios recién creados quedan accesibles
# de inmediato. También pide, una sola vez, una contraseña opcional para
# esos mismos usuarios (ENTER para dejarlos solo con acceso por llave).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
ADMIN_USER="${PRUEBA_AGENTES_ADMIN_USER:-serveradmin}"
KEY_FILE="$HOME/.ssh/id_ed25519"
PUB_KEY_FILE="$KEY_FILE.pub"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no)
[ ! -f "$KEY_FILE" ] || SSH_OPTS+=(-i "$KEY_FILE")

# Regla de nombre de usuario Linux estándar (la misma que exige adduser en
# Debian/Ubuntu): letra o "_" inicial, y luego letras/números/._- .
REGEX_USUARIO='^[a-z_][a-z0-9_-]*$'

# Escapa un valor arbitrario para embeberlo entre comillas simples en un
# comando remoto (mismo patrón que usa tools/despacho/despachar_vm.sh):
# necesario para la contraseña, que puede traer cualquier carácter.
SHELL_QUOTE() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

USO() {
  echo "Uso: ./tools/vms/global/create_users.sh" >&2
  echo "Pide, uno por uno, los nombres de usuario a crear (ENTER vacío para" >&2
  echo "terminar), y los crea en TODAS las VMs de $VMS_CONF: sin sudo, con" >&2
  echo "acceso SSH inmediato vía la llave compartida ($PUB_KEY_FILE)." >&2
  echo "Se conecta a cada VM como '$ADMIN_USER' (override: PRUEBA_AGENTES_ADMIN_USER)." >&2
}

[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { USO; exit 0; }
[ "$#" -eq 0 ] || { echo "Error: este script no recibe argumentos." >&2; USO; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' es obligatorio en la Mac." >&2; exit 1; }
[ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }
[ -s "$PUB_KEY_FILE" ] || { echo "Error: no existe '$PUB_KEY_FILE'. Corré primero ./tools/vms/sync_ssh.sh." >&2; exit 1; }

# Pide usuarios de a uno hasta un ENTER vacío. Corre en un subshell propio
# (invocado vía "< <(...)" en MAIN), así su "read -p" usa la terminal real
# sin pelearse con el bucle que recorre las VMs.
PEDIR_USUARIOS() {
  local nombre
  local usuarios=()
  echo "👤 Ingresá los usuarios a crear en TODAS las VMs (ENTER vacío para terminar):" >&2
  while true; do
    read -r -p "  Usuario #$((${#usuarios[@]} + 1)) (ENTER para terminar): " nombre
    [ -n "$nombre" ] || break
    if [ "$nombre" = "$ADMIN_USER" ]; then
      echo "  ⚠️ '$ADMIN_USER' ya existe y tiene sudo; no hace falta crearlo. Ignorado." >&2
      continue
    fi
    if [[ ! "$nombre" =~ $REGEX_USUARIO ]]; then
      echo "  ⚠️ Nombre inválido (minúsculas/números/guion/guion bajo, sin empezar con número). Ignorado." >&2
      continue
    fi
    usuarios+=("$nombre")
  done
  printf '%s\n' "${usuarios[@]}"
}

OBTENER_PERFILES() {
  jq -r 'to_entries[] | select((.value.ip // "") != "") | .key' "$VMS_CONF"
}

CREAR_USUARIO_EN_VM() {
  local target="$1" usuario="$2" pub_key="$3"
  ssh -tt "${SSH_OPTS[@]}" "$target" "set -eu;
    id -u '$usuario' >/dev/null 2>&1 || sudo useradd -m -s /bin/bash '$usuario';
    sudo install -d -m 700 -o '$usuario' -g '$usuario' '/home/$usuario/.ssh';
    sudo touch '/home/$usuario/.ssh/authorized_keys';
    sudo chmod 600 '/home/$usuario/.ssh/authorized_keys';
    sudo chown '$usuario:$usuario' '/home/$usuario/.ssh/authorized_keys';
    sudo grep -qxF '$pub_key' '/home/$usuario/.ssh/authorized_keys' 2>/dev/null || printf '%s\n' '$pub_key' | sudo tee -a '/home/$usuario/.ssh/authorized_keys' >/dev/null;
  "
}

# El "printf | sudo chpasswd" corre del lado REMOTO (no se canaliza desde el
# stdin local): si le pasáramos la contraseña por el stdin del ssh local,
# chocaría con el prompt de contraseña de sudo, que también necesita leer de
# la terminal (por eso hace falta "-tt" acá). SHELL_QUOTE evita que un
# caracter especial en la contraseña rompa el comando remoto.
ESTABLECER_PASSWORD_EN_VM() {
  local target="$1" usuario="$2" password="$3"
  local q_usuario q_password
  q_usuario="$(SHELL_QUOTE "$usuario")"
  q_password="$(SHELL_QUOTE "$password")"
  ssh -tt "${SSH_OPTS[@]}" "$target" "printf '%s:%s\n' $q_usuario $q_password | sudo chpasswd"
}

MAIN() {
  local usuarios=()
  local linea
  # while+read en vez de "mapfile" (bash 4+): el bash de macOS es 3.2.
  while IFS= read -r linea; do
    [ -n "$linea" ] && usuarios+=("$linea")
  done < <(PEDIR_USUARIOS)

  if [ "${#usuarios[@]}" -eq 0 ]; then
    echo "ℹ️ No se especificó ningún usuario; nada para hacer." >&2
    exit 0
  fi

  # Se pide una sola vez: la misma contraseña se aplica a todos los usuarios
  # de la lista, en todas las VMs. ENTER vacío = no asignar contraseña (el
  # usuario queda solo con acceso por llave SSH, como antes).
  local password
  read -rs -p "🔑 Contraseña para estos usuarios (ENTER para no asignar ninguna): " password
  echo ""

  echo ""
  echo "🔎 Leyendo VMs registradas en $VMS_CONF..."
  local perfiles
  perfiles="$(OBTENER_PERFILES)"
  if [ -z "$perfiles" ]; then
    echo "ℹ️ No hay ninguna VM con IP registrada en $VMS_CONF."
    exit 0
  fi

  local pub_key
  pub_key="$(cat "$PUB_KEY_FILE")"

  echo ""
  echo "Se crearán estos usuarios en cada VM: ${usuarios[*]}"

  local perfil
  local total_ok=0 total_fallidas=0

  # Lee de fd 3, no de stdin: los "ssh -tt" de más abajo (contraseña de sudo)
  # necesitan el stdin real de la terminal libre; si el bucle leyera de
  # stdin, esos prompts se comerían las filas restantes de $perfiles.
  while IFS= read -r -u 3 perfil; do
    [ -n "$perfil" ] || continue
    local ip target
    ip="$(jq -r --arg p "$perfil" '.[$p].ip' "$VMS_CONF")"
    target="$ADMIN_USER@$ip"
    echo ""
    echo "🌐 Perfil '$perfil' ($target)"

    local usuario ok_vm=1
    for usuario in "${usuarios[@]}"; do
      echo "   👤 $usuario..."
      if ! CREAR_USUARIO_EN_VM "$target" "$usuario" "$pub_key"; then
        echo "   ❌ Falló '$usuario' en '$perfil'." >&2
        ok_vm=0
        continue
      fi
      if [ -z "$password" ]; then
        echo "   ✓ $usuario listo (sin contraseña, solo llave SSH)."
        continue
      fi
      if ESTABLECER_PASSWORD_EN_VM "$target" "$usuario" "$password"; then
        echo "   ✓ $usuario listo (con contraseña)."
      else
        echo "   ❌ '$usuario' se creó pero falló al asignar la contraseña en '$perfil'." >&2
        ok_vm=0
      fi
    done

    if [ "$ok_vm" -eq 1 ]; then
      total_ok=$((total_ok + 1))
    else
      total_fallidas=$((total_fallidas + 1))
    fi
  done 3<<< "$perfiles"

  echo ""
  echo "------------------------------------------------------------"
  echo "✅ Usuarios creados sin errores en $total_ok VM(s); con errores: $total_fallidas."
}

MAIN
