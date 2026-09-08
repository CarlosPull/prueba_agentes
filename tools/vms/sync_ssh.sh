#!/usr/bin/env bash
# Provisiona el acceso SSH para todas las VMs registradas en vms.json: genera
# (si falta) una única llave ED25519 en esta Mac, confirma que esté autorizada
# en GitHub, y la copia a cada VM listada en users[] para que (a) la Mac pueda
# conectarse a esa VM sin contraseña y (b) la propia VM pueda autenticarse
# ante GitHub con esa misma identidad (necesario para 'git push'/'gh pr create'
# durante el despacho, ver tools/despacho/despachar_vm.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

KEY_FILE="$HOME/.ssh/id_ed25519"
PUB_KEY_FILE="$KEY_FILE.pub"

# BatchMode=yes: para comprobar si el acceso sin contraseña ya funciona, sin
# quedar esperando una contraseña que no vamos a escribir.
SSH_OPTS_PRUEBA=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
# Sin BatchMode: para la primera copia de la llave, donde SSH sí puede
# necesitar pedir la contraseña actual de la cuenta.
SSH_OPTS_COPIA=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no)

USO() {
  echo "Uso: ./tools/vms/sync_ssh.sh [nombre-de-usuario|--todos]" >&2
  echo "Genera (si falta) una llave SSH local y la distribuye a las VMs" >&2
  echo "registradas en $VMS_CONF, dejándolas listas para el acceso desde esta" >&2
  echo "Mac y para que cada VM se autentique ante GitHub con la misma llave." >&2
  echo "  nombre-de-usuario: opcional, acota a un solo 'users[].name'." >&2
  echo "                     Sin argumento, usa el usuario actual de esta Mac" >&2
  echo "                     (\$(whoami)), igual que sync_pi.sh." >&2
  echo "  --todos: procesa TODOS los usuarios registrados en vms.json (pedirá" >&2
  echo "           usuario/contraseña de cada cuenta que aún no tenga la llave)." >&2
}

[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || { USO; exit 0; }
[ "$#" -le 1 ] || { echo "Error: este script acepta a lo sumo un argumento." >&2; USO; exit 1; }
if [ "${1:-}" = "--todos" ]; then
  USUARIO_FILTRO=""
else
  USUARIO_FILTRO="${1:-$(whoami)}"
fi

VERIFICAR_DEPENDENCIAS() {
  local comando
  for comando in jq ssh ssh-keygen; do
    command -v "$comando" >/dev/null 2>&1 || {
      echo "Error: '$comando' es obligatorio en la Mac." >&2
      exit 1
    }
  done
  [ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }
}

GENERAR_LLAVE_LOCAL_SI_FALTA() {
  if [ -f "$KEY_FILE" ]; then
    echo "✓ Llave SSH local ya existe en $KEY_FILE."
    return
  fi
  echo "🔑 Generando nueva llave SSH ED25519 en $KEY_FILE..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "prueba-agentes-vms"
  echo "✓ Llave creada."
}

# Confirma que la llave pública ya está autorizada en GitHub; si no, la
# muestra para copiarla manualmente y espera confirmación. Se hace una sola
# vez al inicio, no por cada VM.
VERIFICAR_LLAVE_EN_GITHUB() {
  echo ""
  echo "🐙 Verificando autenticación SSH con GitHub..."
  local respuesta
  respuesta="$(ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=5 git@github.com 2>&1 || true)"
  if printf '%s\n' "$respuesta" | grep -q "successfully authenticated"; then
    echo "✓ La llave local ya está autorizada en GitHub."
    return
  fi

  echo ""
  echo "------------------------------------------------------------"
  echo "⚠️ Esta llave todavía no está registrada en tu cuenta de GitHub."
  echo "Copia el siguiente contenido y agrégalo en:"
  echo "  https://github.com/settings/keys  (botón 'New SSH key')"
  echo "------------------------------------------------------------"
  cat "$PUB_KEY_FILE"
  echo "------------------------------------------------------------"
  read -r -p "Presiona ENTER una vez que la hayas agregado a GitHub..." _

  respuesta="$(ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=5 git@github.com 2>&1 || true)"
  if printf '%s\n' "$respuesta" | grep -q "successfully authenticated"; then
    echo "✓ Autenticación con GitHub confirmada."
  else
    echo "⚠️ No se pudo confirmar la autenticación con GitHub; se continúa de todos modos."
  fi
}

# Una fila por VM. `user` es la cuenta técnica SSH; users[].name representa
# usuarios de la plataforma y nunca concede una shell en la VM.
OBTENER_VMS_REGISTRADAS() {
  local usuario_filtro="$1"
  jq -r --arg usuario "$usuario_filtro" '
    to_entries[]
    | .key as $perfil | .value as $vm
    | select(($vm.ip // "") != "")
    | select(($usuario == "") or any($vm.users[]?; ((.name // "" | ascii_downcase) == ($usuario | ascii_downcase))))
    | ($vm.user // $vm.users[0].name // "") as $ssh_user
    | select($ssh_user != "")
    | [$perfil, $vm.ip, $ssh_user] | @tsv
  ' "$VMS_CONF"
}

PERFILES_SIN_USUARIOS() {
  jq -r 'to_entries[] | select((.value.users // []) | length == 0) | .key' "$VMS_CONF"
}

PROVISIONAR_ACCESO_ENTRANTE() {
  local ip="$1" usuario="$2"

  # < /dev/null en cada ssh/ssh-copy-id: sin esto, ssh reenvía el stdin del
  # script (el resto de filas del listado de VMs, ver MAIN) al comando
  # remoto, "comiéndose" las filas siguientes y cortando el bucle tras la
  # primera VM.
  if ssh "${SSH_OPTS_PRUEBA[@]}" -i "$KEY_FILE" "$usuario@$ip" "echo OK" < /dev/null >/dev/null 2>&1; then
    echo "  ✓ Acceso sin contraseña ya funcionaba."
    return 0
  fi

  echo "  🚀 Autorizando la llave en '$usuario@$ip' (puede pedir la contraseña actual)..."
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$PUB_KEY_FILE" "${SSH_OPTS_COPIA[@]}" "$usuario@$ip" < /dev/null || {
      echo "  ❌ No se pudo copiar la llave a '$usuario@$ip'." >&2
      return 1
    }
  else
    local pub_key
    pub_key="$(cat "$PUB_KEY_FILE")"
    ssh "${SSH_OPTS_COPIA[@]}" "$usuario@$ip" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pub_key' ~/.ssh/authorized_keys 2>/dev/null || (echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)" < /dev/null || {
      echo "  ❌ No se pudo copiar la llave a '$usuario@$ip'." >&2
      return 1
    }
  fi

  if ssh "${SSH_OPTS_PRUEBA[@]}" -i "$KEY_FILE" "$usuario@$ip" "echo OK" < /dev/null >/dev/null 2>&1; then
    echo "  ✓ Acceso sin contraseña confirmado."
    return 0
  fi
  echo "  ❌ La llave se copió pero la conexión sin contraseña sigue fallando." >&2
  return 1
}

# Instala la MISMA llave como identidad saliente de la VM hacia GitHub.
PROVISIONAR_ACCESO_SALIENTE_GITHUB() {
  local ip="$1" usuario="$2"
  local pub_key priv_key

  pub_key="$(cat "$PUB_KEY_FILE")"
  priv_key="$(cat "$KEY_FILE")"

  ssh "${SSH_OPTS_PRUEBA[@]}" -i "$KEY_FILE" "$usuario@$ip" "
    set -eu
    umask 077
    mkdir -p ~/.ssh
    printf '%s\n' '$priv_key' > ~/.ssh/id_ed25519
    printf '%s\n' '$pub_key' > ~/.ssh/id_ed25519.pub
    chmod 600 ~/.ssh/id_ed25519
    chmod 644 ~/.ssh/id_ed25519.pub
    if ! grep -q 'Host github.com' ~/.ssh/config 2>/dev/null; then
      printf 'Host github.com\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' >> ~/.ssh/config
      chmod 600 ~/.ssh/config
    fi
  " < /dev/null || { echo "  ❌ No se pudo instalar la identidad de GitHub en '$usuario@$ip'." >&2; return 1; }

  echo "  ✓ Identidad de GitHub instalada en la VM."
  return 0
}

MAIN() {
  VERIFICAR_DEPENDENCIAS
  GENERAR_LLAVE_LOCAL_SI_FALTA
  VERIFICAR_LLAVE_EN_GITHUB

  echo ""
  if [ -z "$USUARIO_FILTRO" ]; then
    echo "🔎 Leyendo VMs registradas en $VMS_CONF (--todos: todos los usuarios)..."
  else
    echo "🔎 Leyendo VMs registradas en $VMS_CONF (usuario '$USUARIO_FILTRO')..."
  fi
  local filas sin_usuarios
  filas="$(OBTENER_VMS_REGISTRADAS "$USUARIO_FILTRO")"
  sin_usuarios="$(PERFILES_SIN_USUARIOS)"

  [ -z "$sin_usuarios" ] || echo "ℹ️ Perfiles sin usuarios registrados (omitidos): $(tr '\n' ' ' <<< "$sin_usuarios")"

  if [ -z "$filas" ]; then
    if [ -n "$USUARIO_FILTRO" ]; then
      echo "ℹ️ No se encontró ningún usuario '$USUARIO_FILTRO' registrado en $VMS_CONF."
    else
      echo "ℹ️ No hay ninguna VM con usuarios registrados en $VMS_CONF."
    fi
    exit 0
  fi

  local perfil ip usuario
  local total_ok=0 total_fallidas=0

  while IFS=$'\t' read -r perfil ip usuario; do
    [ -n "$perfil" ] || continue
    echo ""
    echo "🌐 Perfil '$perfil' ($usuario@$ip)"

    if [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || [[ ! "$usuario" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "  ⚠️ IP o usuario con formato inseguro; omitido." >&2
      total_fallidas=$((total_fallidas + 1))
      continue
    fi

    if PROVISIONAR_ACCESO_ENTRANTE "$ip" "$usuario" && PROVISIONAR_ACCESO_SALIENTE_GITHUB "$ip" "$usuario"; then
      total_ok=$((total_ok + 1))
    else
      total_fallidas=$((total_fallidas + 1))
    fi
  done <<< "$filas"

  echo ""
  echo "------------------------------------------------------------"
  echo "✅ Acceso provisionado en $total_ok VM(s); con errores: $total_fallidas."
}

MAIN
