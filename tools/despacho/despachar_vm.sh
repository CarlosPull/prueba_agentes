#!/usr/bin/env bash
# Herramienta 3: sincronizar y ejecutar con Pi en la VM correspondiente al rol.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$ROOT/tools"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
ROLE="${1:-}"
PROJECT_DIR="${2:-}"
TAREA="${3:-}"
shift "$([ "$#" -ge 3 ] && echo 3 || echo 0)"
PROFILE_OVERRIDE=""
REPOSITORY_ID=""
DISPATCH_ID="$ROLE"
READ_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || { echo "Error: falta --profile." >&2; exit 1; }; PROFILE_OVERRIDE="$2"; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || { echo "Error: falta --repository." >&2; exit 1; }; REPOSITORY_ID="$2"; shift 2 ;;
    --dispatch-id) [ "$#" -ge 2 ] || { echo "Error: falta --dispatch-id." >&2; exit 1; }; DISPATCH_ID="$2"; shift 2 ;;
    --read-only) READ_ONLY=1; shift ;;
    *) echo "Error: opción no reconocida: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$ROLE" ] || [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despacho/despachar_vm.sh <rol> <directorio_proyecto> \"Tarea\" [--profile perfil --repository repo --dispatch-id id]" >&2
  exit 1
fi
[[ "$ROLE" =~ ^[a-z0-9-]+$ ]] || { echo "Error: rol no válido." >&2; exit 1; }
[[ "$DISPATCH_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Error: dispatch-id no válido." >&2; exit 1; }
[ -d "$PROJECT_DIR" ] || { echo "Error: no existe '$PROJECT_DIR'." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq es obligatorio." >&2; exit 1; }

SHELL_QUOTE() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
GET_VM_FIELD() {
  jq -er --arg profile "$1" --arg field "$2" '.[$profile][$field]' "$VMS_CONF" 2>/dev/null || true
}

perfiles=()
if [ -n "$PROFILE_OVERRIDE" ]; then
  jq -e --arg profile "$PROFILE_OVERRIDE" --arg role "$ROLE" '
    .[$profile].stack == $role and .[$profile].engine == "pi" and .[$profile].dispatch_enabled == true
  ' "$VMS_CONF" >/dev/null || { echo "Error: perfil '$PROFILE_OVERRIDE' no está habilitado para '$ROLE'." >&2; exit 1; }
  perfiles+=("$PROFILE_OVERRIDE")
else
  while IFS= read -r profile; do
    [ -n "$profile" ] && perfiles+=("$profile")
  done < <(jq -r --arg role "$ROLE" '
    to_entries[] | select(.value.stack == $role and .value.engine == "pi" and .value.dispatch_enabled == true) | .key
  ' "$VMS_CONF")
fi

if [ "${#perfiles[@]}" -eq 0 ]; then
  echo "Error: no existe una VM Pi habilitada para el rol '$ROLE'." >&2
  echo "Configura una con ./tools/vms/provisionar_vm_pi.sh <perfil-vm>." >&2
  exit 1
fi
if [ "${#perfiles[@]}" -gt 1 ]; then
  echo "Error: hay varias VMs Pi habilitadas para '$ROLE': ${perfiles[*]}." >&2
  echo "El analista debe indicar --profile y --repository." >&2
  exit 1
fi

PROFILE="${perfiles[0]}"
ip="$(GET_VM_FIELD "$PROFILE" ip)"
user="$(GET_VM_FIELD "$PROFILE" user)"
workspace_default="$(GET_VM_FIELD "$PROFILE" workspace)"
remote_agent="$(GET_VM_FIELD "$PROFILE" remote_agent)"
pi_harness="$(GET_VM_FIELD "$PROFILE" pi_harness)"
pi_provider="$(GET_VM_FIELD "$PROFILE" pi_provider)"
pi_model="$(GET_VM_FIELD "$PROFILE" pi_model)"
node_version="$(GET_VM_FIELD "$PROFILE" node_version)"
repository_count="$(jq -r --arg profile "$PROFILE" '(.[$profile].repositories // []) | length' "$VMS_CONF")"
if [ -z "$REPOSITORY_ID" ]; then
  if [ "$repository_count" -eq 1 ]; then
    REPOSITORY_ID="$(jq -r --arg profile "$PROFILE" '.[$profile].repositories[0].id' "$VMS_CONF")"
  elif [ "$repository_count" -gt 1 ]; then
    echo "Error: '$PROFILE' contiene varios repositorios; indica --repository." >&2
    exit 1
  fi
fi
if [ -n "$REPOSITORY_ID" ]; then
  repository_json="$(jq -ec --arg profile "$PROFILE" --arg repository "$REPOSITORY_ID" '.[$profile].repositories[] | select(.id == $repository)' "$VMS_CONF")" || {
    echo "Error: el repositorio '$REPOSITORY_ID' no pertenece al perfil '$PROFILE'." >&2
    exit 1
  }
  workspace="$(jq -r '.path' <<< "$repository_json")"
  module="$(jq -r '.module' <<< "$repository_json")"
  repository_kind="$(jq -r '.kind' <<< "$repository_json")"
  business_memory="$(jq -r '.business_memory // ""' <<< "$repository_json")"
else
  workspace="$workspace_default"
  module="$ROLE"
  repository_kind="$ROLE"
  business_memory=""
  REPOSITORY_ID="$ROLE"
fi
memory_enabled="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.enabled // false' "$VMS_CONF")"
memory_gateway_url="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.gateway_url // ""' "$VMS_CONF")"
memory_core_id="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.core_id // ""' "$VMS_CONF")"
memory_tenant_id="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.tenant_id // ""' "$VMS_CONF")"
memory_read_business="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.read_business // false' "$VMS_CONF")"
memory_read_company="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.read_company // false' "$VMS_CONF")"
memory_tls_key="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.tls_key // ""' "$VMS_CONF")"
memory_tls_cert="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.tls_cert // ""' "$VMS_CONF")"
memory_tls_ca="$(jq -r --arg profile "$PROFILE" '.[$profile].memory.tls_ca // ""' "$VMS_CONF")"
[ -n "$pi_harness" ] || pi_harness="/home/$user/.local/bin/pi-harness"
[ -n "$pi_provider" ] || pi_provider="openai-codex"
[ -n "$pi_model" ] || pi_model="gpt-5.4-mini"

for value in "$ip" "$user" "$workspace" "$remote_agent" "$node_version"; do
  [ -n "$value" ] || { echo "Error: configuración Pi incompleta para '$PROFILE'." >&2; exit 1; }
done
[[ "$REPOSITORY_ID" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$module" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "Error: repositorio o módulo no válido para '$PROFILE'." >&2; exit 1;
}
[[ "$workspace" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || { echo "Error: workspace de repositorio inseguro." >&2; exit 1; }
if [ -n "$business_memory" ]; then
  [[ "$business_memory" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.md$ ]] || { echo "Error: ruta de memoria de negocio insegura." >&2; exit 1; }
fi
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || {
  echo "Error: usuario o dirección SSH no válidos para '$PROFILE'." >&2; exit 1;
}
[[ "$remote_agent" =~ ^/home/[A-Za-z0-9._-]+/agentes/[A-Za-z0-9._/-]+$ ]] || {
  echo "Error: remote_agent debe permanecer dentro de /home/<usuario>/agentes/." >&2; exit 1;
}
if [ "$memory_enabled" = "true" ]; then
  [[ "$memory_gateway_url" =~ ^https://[^[:space:]]+$ ]] || {
    echo "Error: memory.gateway_url debe usar HTTPS para '$PROFILE'." >&2; exit 1;
  }
  [[ "$memory_core_id" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "Error: memory.core_id no es válido para '$PROFILE'." >&2; exit 1;
  }
  for credential in "$memory_tls_key" "$memory_tls_cert" "$memory_tls_ca"; do
    [[ "$credential" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || {
      echo "Error: ruta mTLS inválida para '$PROFILE': '$credential'." >&2; exit 1;
    }
  done
fi

# La VM consulta Git antes de ejecutar; la Mac no copia el agente en el despacho.
"$ROOT/tools/sincronizacion/sincronizar_agente.sh" "$PROFILE" >&2

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

q_agent_dir="$(SHELL_QUOTE "$remote_agent/actual")"
q_agent_base="$(SHELL_QUOTE "$remote_agent")"
q_workspace="$(SHELL_QUOTE "$workspace")"
q_harness="$(SHELL_QUOTE "$pi_harness")"
q_role="$(SHELL_QUOTE "$ROLE")"
q_profile="$(SHELL_QUOTE "$PROFILE")"
q_provider="$(SHELL_QUOTE "$pi_provider")"
q_model="$(SHELL_QUOTE "$pi_model")"
node_directory="$node_version"
[[ "$node_directory" == v* ]] || node_directory="v$node_directory"
q_node_path="$(SHELL_QUOTE "/home/$user/.nvm/versions/node/$node_directory/bin:/home/$user/.local/bin")"
q_repository="$(SHELL_QUOTE "$REPOSITORY_ID")"
q_module="$(SHELL_QUOTE "$module")"
q_repository_kind="$(SHELL_QUOTE "$repository_kind")"
q_business_memory="$(SHELL_QUOTE "$business_memory")"
q_memory_enabled="$(SHELL_QUOTE "$([ "$memory_enabled" = "true" ] && echo 1 || echo 0)")"
q_memory_gateway_url="$(SHELL_QUOTE "$memory_gateway_url")"
q_memory_core_id="$(SHELL_QUOTE "$memory_core_id")"
q_memory_tenant_id="$(SHELL_QUOTE "$memory_tenant_id")"
q_memory_read_business="$(SHELL_QUOTE "$([ "$memory_read_business" = "true" ] && echo 1 || echo 0)")"
q_memory_read_company="$(SHELL_QUOTE "$([ "$memory_read_company" = "true" ] && echo 1 || echo 0)")"
q_memory_tls_key="$(SHELL_QUOTE "$memory_tls_key")"
q_memory_tls_cert="$(SHELL_QUOTE "$memory_tls_cert")"
q_memory_tls_ca="$(SHELL_QUOTE "$memory_tls_ca")"
q_read_only="$(SHELL_QUOTE "$READ_ONLY")"

REMOTE_CMD="set -eu;
AGENT_DIR=$q_agent_dir;
AGENT_BASE=$q_agent_base;
WORKSPACE=$q_workspace;
PI_HARNESS=$q_harness;
ROLE=$q_role;
PROFILE=$q_profile;
PROVIDER=$q_provider;
MODEL=$q_model;
REPOSITORY=$q_repository;
MODULE=$q_module;
REPOSITORY_KIND=$q_repository_kind;
BUSINESS_MEMORY=$q_business_memory;
PI_MEMORY_ENABLED=$q_memory_enabled;
PI_MEMORY_GATEWAY_URL=$q_memory_gateway_url;
PI_MEMORY_CORE_ID=$q_memory_core_id;
PI_MEMORY_TENANT_ID=$q_memory_tenant_id;
PI_MEMORY_ALLOW_BUSINESS=$q_memory_read_business;
PI_MEMORY_ALLOW_COMPANY=$q_memory_read_company;
PI_MEMORY_TLS_KEY=$q_memory_tls_key;
PI_MEMORY_TLS_CERT=$q_memory_tls_cert;
PI_MEMORY_TLS_CA=$q_memory_tls_ca;
PI_HARNESS_READ_ONLY=$q_read_only;
exec 8>\"\$AGENT_BASE/.actualizacion.lock\";
flock -s 8;
test -z \"\$BUSINESS_MEMORY\" || test -r \"\$BUSINESS_MEMORY\" || { printf 'Error: falta memoria de negocio local en %s.\n' \"\$BUSINESS_MEMORY\" >&2; exit 1; };
test -s \"\$AGENT_DIR/SKILL.md\";
test -x \"\$PI_HARNESS\" || { printf 'Error: falta pi-harness en %s. Provisiona %s.\n' \"\$PI_HARNESS\" \"\$PROFILE\" >&2; exit 1; };
VERSION=\$(cat \"\$AGENT_DIR/.agent-version\");
AGENT_RESOLVED=\$(readlink -f \"\$AGENT_DIR\");
GIT_COMMIT=\$(cat \"\$AGENT_DIR/.git-commit\" 2>/dev/null || true);
SKILL_SHA256=\$(sha256sum \"\$AGENT_DIR/SKILL.md\" | awk '{print \$1}');
TAREA=\$(cat);
export PATH=$q_node_path:\"\$PATH\";
export PI_MEMORY_ENABLED PI_MEMORY_GATEWAY_URL PI_MEMORY_CORE_ID PI_MEMORY_TENANT_ID PI_MEMORY_ALLOW_BUSINESS PI_MEMORY_ALLOW_COMPANY PI_MEMORY_TLS_KEY PI_MEMORY_TLS_CERT PI_MEMORY_TLS_CA PI_HARNESS_READ_ONLY;
PI_BIN=\$(command -v pi || true);
PI_VERSION=\$(pi --version 2>/dev/null | head -n 1 || true);
printf 'REPOSITORIO: %s\n' \"\$REPOSITORY\" >&2;
printf 'MODULO: %s\n' \"\$MODULE\" >&2;
printf 'TIPO_REPOSITORIO: %s\n' \"\$REPOSITORY_KIND\" >&2;
printf 'MEMORIA_NEGOCIO_LOCAL: %s\n' \"\$BUSINESS_MEMORY\" >&2;
test -n \"\$PI_BIN\" || { echo 'Error: Pi no está disponible en PATH.' >&2; exit 1; };
printf 'PERFIL_VM: %s\n' \"\$PROFILE\" >&2;
printf 'AGENTE_RESUELTO: %s\n' \"\$AGENT_RESOLVED\" >&2;
printf 'VERSION_AGENTE: %s\n' \"\$VERSION\" >&2;
printf 'COMMIT_AGENTE: %s\n' \"\$GIT_COMMIT\" >&2;
printf 'SHA256_SKILL: %s\n' \"\$SKILL_SHA256\" >&2;
printf 'WORKSPACE_REMOTO: %s\n' \"\$WORKSPACE\" >&2;
printf 'PI_HARNESS_REMOTO: %s\n' \"\$PI_HARNESS\" >&2;
printf 'PI_BIN: %s\n' \"\$PI_BIN\" >&2;
printf 'PI_VERSION: %s\n' \"\$PI_VERSION\" >&2;
READ_ONLY_ARG='';
[ \"\$PI_HARNESS_READ_ONLY\" != 1 ] || READ_ONLY_ARG='--read-only';
if [ -n \"\$BUSINESS_MEMORY\" ]; then
  printf '%s\n' \"\$TAREA\" | \"\$PI_HARNESS\" start --role \"\$ROLE\" --workspace \"\$WORKSPACE\" --agent-dir \"\$AGENT_DIR\" --business-memory \"\$BUSINESS_MEMORY\" --backend auto --provider \"\$PROVIDER\" --model \"\$MODEL\" \$READ_ONLY_ARG --task -;
else
  printf '%s\n' \"\$TAREA\" | \"\$PI_HARNESS\" start --role \"\$ROLE\" --workspace \"\$WORKSPACE\" --agent-dir \"\$AGENT_DIR\" --backend auto --provider \"\$PROVIDER\" --model \"\$MODEL\" \$READ_ONLY_ARG --task -;
fi"

LOG_FILE="$PROJECT_DIR/${DISPATCH_ID}_output.log"
echo "▶️ Ejecutando con Pi '$ROLE' mediante '$PROFILE' ($user@$ip)..." >&2
{
  echo "AGENTE_REMOTO: $remote_agent/actual"
  echo "PERFIL_VM_LOCAL: $PROFILE"
  echo "ROL: $ROLE"
  echo "DESPACHO_ID: $DISPATCH_ID"
  ssh "${SSH_OPTS[@]}" "$user@$ip" "$REMOTE_CMD" <<< "$TAREA"
} > "$LOG_FILE" 2>&1

"$ROOT/tools/despacho/generar_evidencia_agente.sh" "$ROLE" "$PROJECT_DIR" "$DISPATCH_ID" >/dev/null
"$ROOT/tools/despacho/generar_reporte.sh" "$PROJECT_DIR" "$TAREA" --actualizar "$DISPATCH_ID" >/dev/null 2>&1 || true
echo "$LOG_FILE"

