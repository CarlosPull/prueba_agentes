#!/usr/bin/env bash
# Registra un repositorio/módulo adicional en una VM y crea su memoria local.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PRIVATE_TECH_MEMORY="${PRUEBA_AGENTES_PRIVATE_TECH_MEMORY:-$ROOT/.private/tecnologias.json}"
PROFILE="${1:-}"
REPOSITORY="${2:-}"
MODULE="${3:-}"
KIND="${4:-}"
LOCAL_PATH="${5:-}"
REMOTE_PATH="${6:-}"
ALIASES_CSV="${7:-$REPOSITORY,$MODULE}"
MODE="${8:-}"

if [ -z "$PROFILE" ] || [ -z "$REPOSITORY" ] || [ -z "$MODULE" ] || [ -z "$KIND" ] || [ -z "$LOCAL_PATH" ] || [ -z "$REMOTE_PATH" ]; then
  echo "Uso: ./tools/vms/agregar_repositorio_vm.sh <perfil> <repo-id> <modulo> <module|core|frontend> <ruta-local> <ruta-remota> [aliases,separados,por,coma] [--solo-configurar]" >&2
  exit 1
fi
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$REPOSITORY" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$MODULE" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "Error: perfil, repositorio o módulo no válido." >&2; exit 1;
}
case "$KIND" in module|core|frontend) ;; *) echo "Error: tipo inválido; usa module, core o frontend." >&2; exit 1 ;; esac
[ -d "$LOCAL_PATH" ] || { echo "Error: no existe el proyecto local '$LOCAL_PATH'." >&2; exit 1; }
REFRESCAR_TECH=0
FORZAR_CONFIG=0

for arg in "${@:8}"; do
  case "$arg" in
    --solo-configurar) FORZAR_CONFIG=1 ;;
    --refrescar-tecnologias) REFRESCAR_TECH=1 ;;
    *) echo "Error: opción no reconocida '$arg'." >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }

user="$(jq -er --arg profile "$PROFILE" '.[$profile].user' "$VMS_CONF")" || { echo "Error: perfil '$PROFILE' inexistente." >&2; exit 1; }
ip="$(jq -er --arg profile "$PROFILE" '.[$profile].ip' "$VMS_CONF")"
stack="$(jq -er --arg profile "$PROFILE" '.[$profile].stack' "$VMS_CONF")"
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "Error: usuario o IP inseguros en '$PROFILE'." >&2; exit 1; }
[[ "$REMOTE_PATH" =~ ^/home/$user/[A-Za-z0-9._/-]+$ ]] || { echo "Error: la ruta remota debe permanecer dentro de /home/$user/." >&2; exit 1; }
if [ "$stack" = "frontend" ] && [ "$KIND" != "frontend" ]; then
  echo "Error: una VM frontend sólo admite repositorios de tipo frontend." >&2; exit 1
fi
jq -e --arg profile "$PROFILE" --arg repository "$REPOSITORY" \
  'all((.[$profile].repositories // [])[]; .id != $repository)' "$VMS_CONF" >/dev/null || {
    if [ "$REFRESCAR_TECH" -eq 0 ]; then
      echo "Error: '$REPOSITORY' ya está registrado en '$PROFILE'. Usa --refrescar-tecnologias para actualizar manifiestos." >&2; exit 1;
    fi
  }

detected_technology="$($ROOT/tools/vms/detectar_tecnologias_repositorio.sh "$LOCAL_PATH" "$KIND")"
jq -e '.technologies | type == "array"' <<< "$detected_technology" >/dev/null
private_parent="${PRIVATE_TECH_MEMORY%/*}"
[ "$private_parent" != "$PRIVATE_TECH_MEMORY" ] || private_parent="."
[ "$private_parent" = "." ] || install -d -m 0700 "$private_parent"
technology_tmp=""
config_tmp=""
technology_action="preservada"

if [ -s "$PRIVATE_TECH_MEMORY" ]; then
  jq -e '.version == 1 and (.repositories | type == "object")' "$PRIVATE_TECH_MEMORY" >/dev/null || {
    echo "Error: inventario tecnológico privado inválido: $PRIVATE_TECH_MEMORY" >&2; exit 1;
  }
  if [ "$REFRESCAR_TECH" -eq 1 ] || ! jq -e --arg repository "$REPOSITORY" '.repositories | has($repository)' "$PRIVATE_TECH_MEMORY" >/dev/null; then
    technology_tmp="$(mktemp "$PRIVATE_TECH_MEMORY.XXXXXX")"
    jq --arg repository "$REPOSITORY" --argjson technology "$detected_technology" \
      '.repositories[$repository] = $technology' "$PRIVATE_TECH_MEMORY" > "$technology_tmp"
    technology_action="detectada y actualizada"
  fi
else
  technology_tmp="$(mktemp "$PRIVATE_TECH_MEMORY.XXXXXX")"
  jq -n --arg repository "$REPOSITORY" --argjson technology "$detected_technology" \
    '{version:1,repositories:{($repository):$technology}}' > "$technology_tmp"
  technology_action="detectada"
fi
[ -z "$technology_tmp" ] || chmod 0600 "$technology_tmp"
trap '[ -z "$config_tmp" ] || rm -f "$config_tmp"; [ -z "$technology_tmp" ] || rm -f "$technology_tmp"' EXIT INT TERM

memory_path="/home/$user/.local/share/prueba-agentes/business/$REPOSITORY.md"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
if [ "$FORZAR_CONFIG" -eq 0 ]; then
  command -v rsync >/dev/null 2>&1 || { echo "Error: rsync es obligatorio." >&2; exit 1; }
  echo "📤 Copiando '$REPOSITORY' a $user@$ip:$REMOTE_PATH..."
  ssh "${SSH_OPTS[@]}" "$user@$ip" "install -d -m 0750 '$REMOTE_PATH'"
  rsync -az --delete --exclude='.git/' -e "ssh ${SSH_OPTS[*]}" "$LOCAL_PATH/" "$user@$ip:$REMOTE_PATH/"
fi

memory_parent="${memory_path%/*}"
ssh "${SSH_OPTS[@]}" "$user@$ip" \
  "install -d -m 0700 '$memory_parent'; if [ ! -e '$memory_path' ]; then printf '# Memoria de negocio: %s (%s)\n\nDescribe aquí únicamente las reglas privadas de este módulo.\n' '$MODULE' '$REPOSITORY' > '$memory_path'; fi; chmod 0600 '$memory_path'" 2>/dev/null || true

aliases_json="$(printf '%s' "$ALIASES_CSV" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
config_tmp="$(mktemp "$VMS_CONF.repositorio.XXXXXX")"
jq --arg profile "$PROFILE" --arg id "$REPOSITORY" --arg module "$MODULE" --arg kind "$KIND" \
  --arg path "$REMOTE_PATH" --arg business_memory "$memory_path" --argjson aliases "$aliases_json" '
  .[$profile].repositories = ((.[$profile].repositories // []) + [{
    id:$id,module:$module,kind:$kind,path:$path,business_memory:$business_memory,aliases:$aliases
  }])
' "$VMS_CONF" > "$config_tmp"
[ -z "$technology_tmp" ] || mv "$technology_tmp" "$PRIVATE_TECH_MEMORY"
mv "$config_tmp" "$VMS_CONF"
trap - EXIT INT TERM
echo "✓ Repositorio '$REPOSITORY' registrado en '$PROFILE'; el analista ya puede seleccionarlo."
echo "  Tecnología $technology_action: $PRIVATE_TECH_MEMORY"

if [ -f "$ROOT/.private/memory-gateway-pki/clients/memory-admin.crt" ] && [ -f "$ROOT/tools/gateway/memoria_gateway.sh" ]; then
  tech_list="$(jq -r '.technologies | join(", ")' <<< "$detected_technology")"
  if [ -n "$tech_list" ]; then
    export MEMORY_GATEWAY_URL="${MEMORY_GATEWAY_URL:-https://192.168.50.31:9443}"
    export MEMORY_GATEWAY_CLIENT_CERT="${MEMORY_GATEWAY_CLIENT_CERT:-$ROOT/.private/memory-gateway-pki/clients/memory-admin.crt}"
    export MEMORY_GATEWAY_CLIENT_KEY="${MEMORY_GATEWAY_CLIENT_KEY:-$ROOT/.private/memory-gateway-pki/clients/memory-admin.key}"
    export MEMORY_GATEWAY_CA="${MEMORY_GATEWAY_CA:-$ROOT/.private/memory-gateway-pki/ca.crt}"
    "$ROOT/tools/gateway/memoria_gateway.sh" guardar-empresa "Repositorio $REPOSITORY ($MODULE): $tech_list. Arquitectura $KIND." >/dev/null 2>&1 || true
    echo "  ✓ Sincronizada tecnología en Memory Gateway (capa company)."
  fi
fi

if [ "$(jq '.technologies | length' <<< "$detected_technology")" -eq 0 ] && [ "$technology_action" = "detectada" ]; then
  echo "  Aviso: no se encontraron manifiestos compatibles; completa manualmente la entrada '$REPOSITORY'." >&2
fi
echo "  Memoria de negocio local: $memory_path"
