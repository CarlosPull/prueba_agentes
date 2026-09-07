#!/usr/bin/env bash
# Borra usuarios de sistema en TODAS las VMs registradas en vms.json. Nunca
# borra a la cuenta con permisos sudo (serveradmin). Se conecta como esa
# cuenta para ejecutar "userdel -r" vía sudo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
ADMIN_USER="${PRUEBA_AGENTES_ADMIN_USER:-serveradmin}"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

REGEX_USUARIO='^[a-z_][a-z0-9_-]*$'
MODO_TODOS=0

USO() {
  echo "Uso: ./tools/vms/global/delete_users.sh [--all]" >&2
  echo "Sin argumentos: pide, uno por uno, los usuarios a borrar (ENTER vacío" >&2
  echo "para terminar) y los borra (con su home, 'userdel -r') en TODAS las" >&2
  echo "VMs de $VMS_CONF." >&2
  echo "  --all: borra TODOS los usuarios humanos (uid 1000-59999) detectados" >&2
  echo "         en cada VM, excepto '$ADMIN_USER'." >&2
  echo "'$ADMIN_USER' (override: PRUEBA_AGENTES_ADMIN_USER) nunca se borra," >&2
  echo "tenga o no la bandera --all. Pide confirmación antes de ejecutar." >&2
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) USO; exit 0 ;;
    --all) MODO_TODOS=1 ;;
    *) echo "Error: opción no reconocida '$arg'." >&2; USO; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' es obligatorio en la Mac." >&2; exit 1; }
[ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }

# Pide usuarios de a uno hasta un ENTER vacío (mismo criterio que create_users.sh).
PEDIR_USUARIOS() {
  local nombre
  local usuarios=()
  echo "👤 Ingresá los usuarios a borrar en TODAS las VMs (ENTER vacío para terminar):" >&2
  while true; do
    read -r -p "  Usuario #$((${#usuarios[@]} + 1)) (ENTER para terminar): " nombre
    [ -n "$nombre" ] || break
    if [ "$nombre" = "$ADMIN_USER" ]; then
      echo "  ⚠️ '$ADMIN_USER' no se puede borrar (es la cuenta con sudo). Ignorado." >&2
      continue
    fi
    if [[ ! "$nombre" =~ $REGEX_USUARIO ]]; then
      echo "  ⚠️ Nombre inválido. Ignorado." >&2
      continue
    fi
    usuarios+=("$nombre")
  done
  printf '%s\n' "${usuarios[@]}"
}

OBTENER_PERFILES() {
  jq -r 'to_entries[] | select((.value.ip // "") != "") | .key' "$VMS_CONF"
}

# Usuarios humanos reales en la VM (uid 1000-59999), excluyendo $ADMIN_USER.
# El filtro corre en la Mac (sobre el "getent passwd" ya traído), para no
# tener que escapar awk dentro del comando remoto.
LISTAR_USUARIOS_VM() {
  local target="$1"
  local passwd_remoto
  passwd_remoto="$(ssh "${SSH_OPTS[@]}" "$target" "getent passwd" 2>/dev/null)" || return 1
  awk -F: -v admin="$ADMIN_USER" '$3>=1000 && $3<60000 && $1!=admin {print $1}' <<< "$passwd_remoto"
}

BORRAR_USUARIO_EN_VM() {
  local target="$1" usuario="$2"
  if [ "$usuario" = "$ADMIN_USER" ]; then
    echo "  ⚠️ Se ignoró un intento de borrar '$ADMIN_USER'." >&2
    return 1
  fi
  ssh -tt "${SSH_OPTS[@]}" "$target" "sudo userdel -r '$usuario'"
}

MAIN() {
  echo "🔎 Leyendo VMs registradas en $VMS_CONF..."
  local perfiles
  perfiles="$(OBTENER_PERFILES)"
  if [ -z "$perfiles" ]; then
    echo "ℹ️ No hay ninguna VM con IP registrada en $VMS_CONF."
    exit 0
  fi

  local usuarios_fijos=()
  if [ "$MODO_TODOS" -eq 0 ]; then
    mapfile -t usuarios_fijos < <(PEDIR_USUARIOS)
    if [ "${#usuarios_fijos[@]}" -eq 0 ]; then
      echo "ℹ️ No se especificó ningún usuario; nada para hacer." >&2
      exit 0
    fi
    echo ""
    echo "Se borrarán estos usuarios en cada VM: ${usuarios_fijos[*]}"
  else
    echo ""
    echo "⚠️ Modo --all: se borrará TODO usuario humano (uid 1000-59999) de cada VM, excepto '$ADMIN_USER'."
  fi

  read -r -p "¿Confirmás? Escribí 'ELIMINAR' para continuar: " confirmacion
  [ "$confirmacion" = "ELIMINAR" ] || { echo "Cancelado."; exit 0; }

  local perfil
  local total_ok=0 total_fallidas=0

  # Lee de fd 3, no de stdin: mismo motivo que en create_users.sh.
  while IFS= read -r -u 3 perfil; do
    [ -n "$perfil" ] || continue
    local ip target
    ip="$(jq -r --arg p "$perfil" '.[$p].ip' "$VMS_CONF")"
    target="$ADMIN_USER@$ip"
    echo ""
    echo "🌐 Perfil '$perfil' ($target)"

    local usuarios_vm=()
    if [ "$MODO_TODOS" -eq 1 ]; then
      local listado
      if ! listado="$(LISTAR_USUARIOS_VM "$target")"; then
        echo "  ❌ No se pudo listar usuarios en '$perfil'." >&2
        total_fallidas=$((total_fallidas + 1))
        continue
      fi
      [ -z "$listado" ] || mapfile -t usuarios_vm <<< "$listado"
      if [ "${#usuarios_vm[@]}" -eq 0 ]; then
        echo "  ℹ️ No hay usuarios para borrar (además de '$ADMIN_USER')."
        total_ok=$((total_ok + 1))
        continue
      fi
      echo "  Usuarios detectados: ${usuarios_vm[*]}"
    else
      usuarios_vm=("${usuarios_fijos[@]}")
    fi

    local usuario ok_vm=1
    for usuario in "${usuarios_vm[@]}"; do
      echo "   👤 $usuario..."
      if BORRAR_USUARIO_EN_VM "$target" "$usuario"; then
        echo "   ✓ $usuario borrado."
      else
        echo "   ❌ Falló '$usuario' en '$perfil'." >&2
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
  echo "✅ Procesado sin errores en $total_ok VM(s); con errores: $total_fallidas."
}

MAIN
