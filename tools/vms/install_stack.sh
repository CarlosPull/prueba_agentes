#!/usr/bin/env bash
# Instala globalmente (para cualquier usuario del sistema) el stack necesario
# para trabajar con Laravel (PHP+Composer), Vue (Node/npm) y Pi
# (pi-coding-agent), además de Podman, en cada VM registrada en vms.json.
# Recorre máquina por máquina pidiendo el usuario con sudo; la contraseña la
# piden SSH y sudo directamente en la terminal (este script nunca la lee ni
# la guarda).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PAQUETES_BACKEND_LOCAL="$ROOT/tools/remotos/instalar_paquetes_backend.sh"
INSTALL_STACK_LOCAL="$ROOT/tools/remotos/install_stack.sh"

# Paquetes base que necesita instalar_paquetes_backend.sh: curl/unzip para
# Composer, software-properties-common para su "add-apt-repository" del PPA.
PAQUETES_BASE_PHP=(git curl ca-certificates unzip software-properties-common)

# Sin BatchMode: SSH puede necesitar pedir la contraseña de la cuenta.
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

USO() {
  echo "Uso: ./tools/vms/install_stack.sh" >&2
  echo "Instala PHP+Composer, Node+npm, pi y Podman de forma global en cada" >&2
  echo "VM de $VMS_CONF. Por cada VM pide el usuario con sudo; la contraseña" >&2
  echo "la piden SSH/sudo directamente en la terminal (nunca se guarda aquí)." >&2
}

[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { USO; exit 0; }
[ "$#" -eq 0 ] || { echo "Error: este script no recibe argumentos." >&2; USO; exit 1; }

VERIFICAR_DEPENDENCIAS() {
  command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' es obligatorio en la Mac." >&2; exit 1; }
  [ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }
  [ -s "$PAQUETES_BACKEND_LOCAL" ] || { echo "Error: falta $PAQUETES_BACKEND_LOCAL." >&2; exit 1; }
  [ -s "$INSTALL_STACK_LOCAL" ] || { echo "Error: falta $INSTALL_STACK_LOCAL." >&2; exit 1; }
}

OBTENER_PERFILES() {
  jq -r 'to_entries[] | select((.value.ip // "") != "") | .key' "$VMS_CONF"
}

# Primer valor no vacío de $campo entre todos los repositorios del perfil;
# si el perfil no tiene ninguno (p. ej. una VM sin usuarios asignados
# todavía), usa el valor por defecto recibido.
OBTENER_VERSION() {
  local perfil="$1" campo="$2" valor_por_defecto="$3"
  local valor
  valor="$(jq -r --arg perfil "$perfil" --arg campo "$campo" '
    .[$perfil].users[]?.repositories[]? | .[$campo] // empty
  ' "$VMS_CONF" | head -n 1)"
  printf '%s' "${valor:-$valor_por_defecto}"
}

# Sube un archivo local a una VM de forma atómica (mismo patrón que usa
# tools/vms/provisionar_vm_pi.sh: instalar en ".nuevo" y luego mover).
INSTALAR_ARCHIVO_REMOTO() {
  local target="$1" archivo_local="$2" ruta_remota="$3"
  ssh "${SSH_OPTS[@]}" "$target" \
    "mkdir -p '$(dirname "$ruta_remota")' && install -m 0755 /dev/stdin '$ruta_remota.nuevo' && mv -f '$ruta_remota.nuevo' '$ruta_remota'" \
    < "$archivo_local"
}

MAIN() {
  VERIFICAR_DEPENDENCIAS

  echo "🔎 Leyendo VMs registradas en $VMS_CONF..."
  local perfiles
  perfiles="$(OBTENER_PERFILES)"
  if [ -z "$perfiles" ]; then
    echo "ℹ️ No hay ninguna VM con IP registrada en $VMS_CONF."
    exit 0
  fi

  local perfil
  local total_ok=0 total_omitidas=0 total_fallidas=0

  # Lee de fd 3 (no de stdin/fd 0): el "read -p" de más abajo y las
  # contraseñas de ssh/sudo necesitan el stdin real de la terminal libre; si
  # el bucle leyera de stdin, esos prompts consumirían las filas restantes
  # de $perfiles y el bucle cortaría tras la primera VM.
  while IFS= read -r -u 3 perfil; do
    [ -n "$perfil" ] || continue
    local ip php_version php_min_version node_version pi_version usuario target ok

    ip="$(jq -r --arg p "$perfil" '.[$p].ip' "$VMS_CONF")"
    php_version="$(OBTENER_VERSION "$perfil" php_version 8.4)"
    php_min_version="$(OBTENER_VERSION "$perfil" php_min_version 8.4.1)"
    node_version="$(OBTENER_VERSION "$perfil" node_version 24.19.0)"
    pi_version="$(OBTENER_VERSION "$perfil" pi_version latest)"

    echo ""
    echo "🌐 Perfil '$perfil' ($ip)"
    echo "   PHP $php_version (mínimo $php_min_version) · Node $node_version · pi $pi_version · Podman"
    read -r -p "   Usuario con sudo en esta VM (ENTER para omitir): " usuario
    if [ -z "$usuario" ]; then
      echo "   ⏭️  Omitida."
      total_omitidas=$((total_omitidas + 1))
      continue
    fi

    if [[ ! "$usuario" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
      echo "   ⚠️ Usuario o IP con formato inseguro; omitida." >&2
      total_fallidas=$((total_fallidas + 1))
      continue
    fi
    target="$usuario@$ip"
    ok=1

    local remoto_backend="/home/$usuario/.local/lib/prueba-agentes/instalar_paquetes_backend.sh"
    local remoto_stack="/home/$usuario/.local/lib/prueba-agentes/install_stack.sh"

    echo "   📦 PHP $php_version + Composer (puede pedir la contraseña de SSH y sudo)..."
    if INSTALAR_ARCHIVO_REMOTO "$target" "$PAQUETES_BACKEND_LOCAL" "$remoto_backend" \
      && ssh -tt "${SSH_OPTS[@]}" "$target" "'$remoto_backend' '$php_version' '$php_min_version' ${PAQUETES_BASE_PHP[*]}"; then
      echo "   ✓ PHP + Composer listos."
    else
      echo "   ❌ Falló la instalación de PHP/Composer." >&2
      ok=0
    fi

    echo "   📦 Node $node_version + pi $pi_version + Podman..."
    if INSTALAR_ARCHIVO_REMOTO "$target" "$INSTALL_STACK_LOCAL" "$remoto_stack" \
      && ssh -tt "${SSH_OPTS[@]}" "$target" "'$remoto_stack' '$node_version' '$pi_version'"; then
      echo "   ✓ Node + pi + Podman listos."
    else
      echo "   ❌ Falló la instalación de Node/pi/Podman." >&2
      ok=0
    fi

    if [ "$ok" -eq 1 ]; then
      total_ok=$((total_ok + 1))
    else
      total_fallidas=$((total_fallidas + 1))
    fi
  done 3<<< "$perfiles"

  echo ""
  echo "------------------------------------------------------------"
  echo "✅ Stack instalado en $total_ok VM(s); omitidas: $total_omitidas; con errores: $total_fallidas."
}

MAIN
