#!/usr/bin/env bash
# Actualiza la memoria de negocio (.md) privada de un repositorio en una VM.
# Soporta selección interactiva de VM/repositorio o argumentos/pipe en CLI.
# Soporta los modos de sobrescribir (default) o anexar al final (--anexar / --append).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

MODE="overwrite"
if [ "${1:-}" = "--anexar" ] || [ "${1:-}" = "--append" ]; then
  MODE="append"
  shift
fi

PROFILE="${1:-}"
REPO_ID="${2:-}"
INPUT_SOURCE="${3:-}"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para leer vms.json." >&2
  exit 1
}

if [ ! -f "$VMS_CONF" ]; then
  echo "Error: No se encontró el archivo de configuración $VMS_CONF." >&2
  exit 1
fi

# 1. Selección de Perfil de VM
if [ -z "$PROFILE" ]; then
  if [ ! -t 0 ]; then
    echo "Error: Debe especificar el perfil de VM al ejecutar este script por tubería (non-interactive)." >&2
    exit 1
  fi

  profiles=()
  while IFS= read -r p; do
    [ -n "$p" ] && profiles+=("$p")
  done < <(jq -r 'to_entries | map(select(.value.repositories and (.value.repositories | length) > 0)) | .[].key' "$VMS_CONF")

  if [ "${#profiles[@]}" -eq 0 ]; then
    echo "Error: No se encontraron perfiles con repositorios configurados en vms.json." >&2
    exit 1
  fi

  echo "=== Seleccione la Máquina Virtual / Perfil ==="
  for i in "${!profiles[@]}"; do
    p="${profiles[$i]}"
    ip="$(jq -r --arg p "$p" '.[$p].ip // "sin IP"' "$VMS_CONF")"
    repos_str="$(jq -r --arg p "$p" '.[$p].repositories | map(.id) | join(", ")' "$VMS_CONF")"
    printf "%2d) %-22s (IP: %s) -> Repos: [%s]\n" "$((i+1))" "$p" "$ip" "$repos_str"
  done

  while true; do
    read -rp "Seleccione un número (1-${#profiles[@]}): " seleccion
    if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#profiles[@]}" ]; then
      PROFILE="${profiles[$((seleccion-1))]}"
      break
    else
      echo "Selección no válida. Intente de nuevo." >&2
    fi
  done
fi

# Validar que el perfil exista en vms.json
if ! jq -e --arg p "$PROFILE" '.[$p]' "$VMS_CONF" >/dev/null 2>&1; then
  echo "Error: El perfil '$PROFILE' no existe en vms.json." >&2
  exit 1
fi

# 2. Selección de Repositorio dentro del Perfil
repos_json="$(jq -r --arg p "$PROFILE" '.[$p].repositories // []' "$VMS_CONF")"
repo_count="$(jq -r 'length' <<< "$repos_json")"

if [ "$repo_count" -eq 0 ]; then
  echo "Error: El perfil '$PROFILE' no declara repositorios en vms.json." >&2
  exit 1
fi

if [ -z "$REPO_ID" ]; then
  if [ "$repo_count" -eq 1 ]; then
    REPO_ID="$(jq -r '.[0].id' <<< "$repos_json")"
  else
    if [ ! -t 0 ]; then
      echo "Error: El perfil '$PROFILE' tiene múltiples repositorios. Debe especificar el repo_id." >&2
      exit 1
    fi

    repo_ids=()
    while IFS= read -r rid; do
      [ -n "$rid" ] && repo_ids+=("$rid")
    done < <(jq -r '.[].id' <<< "$repos_json")

    echo "=== Seleccione el Repositorio para la VM '$PROFILE' ==="
    for i in "${!repo_ids[@]}"; do
      rid="${repo_ids[$i]}"
      mod="$(jq -r --arg id "$rid" '.[] | select(.id == $id) | .module' <<< "$repos_json")"
      mem="$(jq -r --arg id "$rid" '.[] | select(.id == $id) | .business_memory' <<< "$repos_json")"
      printf "%2d) ID: %-22s Módulo: %-15s Ruta: %s\n" "$((i+1))" "$rid" "$mod" "$mem"
    done

    while true; do
      read -rp "Seleccione un número (1-${#repo_ids[@]}): " seleccion
      if [[ "$seleccion" =~ ^[0-9]+$ ]] && [ "$seleccion" -ge 1 ] && [ "$seleccion" -le "${#repo_ids[@]}" ]; then
        REPO_ID="${repo_ids[$((seleccion-1))]}"
        break
      else
        echo "Selección no válida. Intente de nuevo." >&2
      fi
    done
  fi
fi

# Obtener detalle del repositorio seleccionado
repo_detail="$(jq -r --arg id "$REPO_ID" '.[] | select(.id == $id)' <<< "$repos_json")"
if [ -z "$repo_detail" ]; then
  echo "Error: Repositorio '$REPO_ID' no encontrado en el perfil '$PROFILE'." >&2
  exit 1
fi

business_memory="$(jq -r '.business_memory // ""' <<< "$repo_detail")"
if [ -z "$business_memory" ]; then
  echo "Error: El repositorio '$REPO_ID' no especifica 'business_memory' en vms.json." >&2
  exit 1
fi

if [[ ! "$business_memory" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.md$ ]]; then
  echo "Error: Ruta de memoria de negocio no válida o insegura: '$business_memory'." >&2
  exit 1
fi

ip="$(jq -r --arg p "$PROFILE" '.[$p].ip // ""' "$VMS_CONF")"
user="$(jq -r --arg p "$PROFILE" '.[$p].user // ""' "$VMS_CONF")"

if [ -z "$ip" ] || [ -z "$user" ]; then
  echo "Error: El perfil '$PROFILE' no especifica usuario o IP en vms.json." >&2
  exit 1
fi

if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ip" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Error: Usuario o IP no válidos para el perfil '$PROFILE'." >&2
  exit 1
fi

# Selección de Modo de Escritura (Sobrescribir vs Anexar) si es interactivo y no se especificó flag
if [ -t 0 ] && [ -z "$INPUT_SOURCE" ] && [ "$MODE" = "overwrite" ]; then
  echo "=== Modo de actualización para la memoria ==="
  echo "1) Sobrescribir (Reemplazar todo el contenido por el nuevo)"
  echo "2) Anexar / Agregar al final (Preservar las reglas existentes y agregar las nuevas)"
  read -rp "Seleccione opción (1/2) [Por defecto: 1]: " opt_mode
  if [ "$opt_mode" = "2" ]; then
    MODE="append"
  fi
fi

# 3. Obtener el Contenido de la Memoria de Negocio
CONTENT=""
if [ -n "$INPUT_SOURCE" ]; then
  if [ -f "$INPUT_SOURCE" ]; then
    CONTENT="$(cat "$INPUT_SOURCE")"
  else
    CONTENT="$INPUT_SOURCE"
  fi
elif [ ! -t 0 ]; then
  CONTENT="$(cat)"
else
  echo "=== Método de entrada para el nuevo contenido ==="
  echo "1) Pegar/Escribir texto multilínea (finalizar introduciendo una línea con 'EOF' o Ctrl+D)"
  echo "2) Ruta a un archivo Markdown local (.md)"
  
  read -rp "Opción (1/2): " opcion
  if [ "$opcion" = "2" ]; then
    read -rp "Ingrese la ruta del archivo Markdown local: " file_path
    if [ ! -f "$file_path" ]; then
      echo "Error: El archivo local '$file_path' no existe." >&2
      exit 1
    fi
    CONTENT="$(cat "$file_path")"
  else
    echo "Pegue o escriba el contenido a continuación. Para terminar, presione Enter y escriba 'EOF' o use Ctrl+D:"
    lineas=()
    while IFS= read -r line; do
      [ "$line" = "EOF" ] && break
      lineas+=("$line")
    done
    CONTENT="$(printf '%s\n' "${lineas[@]}")"
  fi
fi

if [ -z "$CONTENT" ]; then
  echo "Error: El contenido de la memoria de negocio no puede estar vacío." >&2
  exit 1
fi

# 4. Actualizar la Memoria en la VM vía SSH
parent="${business_memory%/*}"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

if [ "$MODE" = "append" ]; then
  # Anexar asegurando una nueva línea si el archivo previo ya contenía texto
  printf '%s\n' "$CONTENT" | ssh "${SSH_OPTS[@]}" "$user@$ip" \
    "install -d -m 0700 '$parent' && { [ ! -s '$business_memory' ] || echo ''; } >> '$business_memory' && cat >> '$business_memory' && chmod 0600 '$business_memory'"
  echo "✓ Memoria de negocio ANEXADA exitosamente en '$PROFILE' [$REPO_ID] → $business_memory"
else
  # Sobrescribir completamente
  printf '%s\n' "$CONTENT" | ssh "${SSH_OPTS[@]}" "$user@$ip" \
    "install -d -m 0700 '$parent' && cat > '$business_memory' && chmod 0600 '$business_memory'"
  echo "✓ Memoria de negocio SOBREESCRITA exitosamente en '$PROFILE' [$REPO_ID] → $business_memory"
fi
