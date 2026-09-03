#!/usr/bin/env bash
# Provisiona una VM con Pi y pi-harness, sin instalar ni copiar agent-runner/OpenCode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PRIVATE_TECH_MEMORY="${PRUEBA_AGENTES_PRIVATE_TECH_MEMORY:-$ROOT/.private/tecnologias.json}"
BOOTSTRAP_LOCAL="$ROOT/tools/remotos/provisionar_vm_pi.sh"
PAQUETES_BACKEND_LOCAL="$ROOT/tools/remotos/instalar_paquetes_backend.sh"
APPARMOR_BWRAP_LOCAL="$ROOT/tools/remotos/prueba-agentes-bwrap.apparmor"
HARNESS_LOCAL="$ROOT/pi-harness"
VM_PROFILE="${1:-}"
OPCION="${2:-}"

USO() {
  echo "Uso: ./tools/vms/provisionar_vm_pi.sh <perfil-vm> [--con-sudo-interactivo|--solo-verificar|--solo-configurar]" >&2
}

[ -n "$VM_PROFILE" ] || { USO; exit 1; }
[[ "$VM_PROFILE" =~ ^[a-z0-9-]+$ ]] || {
  echo "Error: el perfil de VM solo puede contener letras minúsculas, números y guiones." >&2
  exit 1
}
if [ -n "$OPCION" ] && [ "$OPCION" != "--con-sudo-interactivo" ] && [ "$OPCION" != "--solo-verificar" ] && [ "$OPCION" != "--solo-configurar" ]; then
  echo "Error: opción no reconocida: '$OPCION'." >&2
  exit 1
fi

for comando in jq ssh rsync; do
  command -v "$comando" >/dev/null 2>&1 || { echo "Error: '$comando' es obligatorio en la Mac." >&2; exit 1; }
done

[ -s "$VMS_CONF" ] || { echo "Error: no existe la configuración '$VMS_CONF'." >&2; exit 1; }

CONFIGURAR_PERFIL_NUEVO() {
  local ip_nuevo user_nuevo stack_nuevo workspace_default workspace_nuevo
  local repository_id_nuevo module_nuevo repository_kind_nuevo aliases_nuevo aliases_json
  local source_mode_nuevo project_local_nuevo project_git_url_nuevo project_git_branch_nuevo
  local agent_update_mode_nuevo git_url_nuevo git_branch_default git_branch_nuevo
  local node_version_nuevo pi_version_nuevo php_version_nuevo php_min_version_nuevo
  local local_agent_nuevo remote_agent_nuevo git_agent_path_nuevo poll_nuevo config_tmp respuesta
  local repositories_root candidate selection default_repository detected_technology technology_tmp technology_action private_parent stack_default
  local repositorios_locales=()

  [ "$OPCION" != "--solo-verificar" ] || {
    echo "Error: no se puede verificar un perfil inexistente: '$VM_PROFILE'." >&2
    exit 1
  }

  echo "🧭 El perfil '$VM_PROFILE' no existe; iniciando configuración inicial."

  local pub_key_file="$HOME/.ssh/id_ed25519.pub"
  local gh_check=""
  if [ -f "$pub_key_file" ]; then
    gh_check="$(ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=4 git@github.com 2>&1 || true)"
    if ! printf '%s\n' "$gh_check" | grep -q "successfully authenticated"; then
      echo ""
      echo "------------------------------------------------------------"
      echo "⚠️ ATENCIÓN: Tu llave SSH aún no está registrada en tu cuenta de GitHub."
      echo "Para que la VM pueda clonar repositorios privados automáticamente:"
      echo "------------------------------------------------------------"
      cat "$pub_key_file"
      echo "------------------------------------------------------------"
      echo "👉 Agrégala en: https://github.com/settings/keys (New SSH key)"
      echo "------------------------------------------------------------"
      read -r -p "Presiona ENTER una vez que la hayas agregado a tu cuenta de GitHub..." _
      echo ""
    fi
  fi



  read -r -p "IP de la VM: " ip_nuevo
  read -r -p "Usuario de Ubuntu: " user_nuevo


  [[ "$ip_nuevo" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "Error: IP no válida." >&2; exit 1; }
  [[ "$user_nuevo" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Error: usuario no válido." >&2; exit 1; }

  read -r -p "Origen del proyecto [local/git] (local): " source_mode_nuevo
  source_mode_nuevo="${source_mode_nuevo:-local}"
  [ "$source_mode_nuevo" = "local" ] || [ "$source_mode_nuevo" = "git" ] || { echo "Error: origen no válido." >&2; exit 1; }

  project_local_nuevo=""
  project_git_url_nuevo=""
  project_git_branch_nuevo=""
  detected_technology=""
  if [ "$source_mode_nuevo" = "local" ]; then
    repositories_root="${PRUEBA_AGENTES_REPOSITORIES_ROOT:-$(dirname "$ROOT")}"
    [ -d "$repositories_root" ] || { echo "Error: no existe el directorio de repositorios '$repositories_root'." >&2; exit 1; }
    while IFS= read -r candidate; do
      if [ -d "$candidate/.git" ] || [ -s "$candidate/composer.json" ] || [ -s "$candidate/package.json" ] || \
         [ -s "$candidate/pyproject.toml" ] || [ -s "$candidate/requirements.txt" ] || [ -s "$candidate/go.mod" ] || \
         [ -s "$candidate/Cargo.toml" ] || [ -s "$candidate/Gemfile" ] || [ -s "$candidate/pom.xml" ] || \
         [ -s "$candidate/build.gradle" ] || [ -s "$candidate/build.gradle.kts" ] || [ -s "$candidate/Dockerfile" ] || \
         [ -s "$candidate/compose.yaml" ] || [ -s "$candidate/docker-compose.yml" ] || \
         find "$candidate" -maxdepth 1 -type f -name '*.csproj' -print -quit | grep -q .; then
        repositorios_locales+=("$candidate")
      fi
    done < <(find "$repositories_root" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)

    echo ""
    echo "📦 Repositorios locales disponibles en $repositories_root:"
    if [ "${#repositorios_locales[@]}" -gt 0 ]; then
      for i in "${!repositorios_locales[@]}"; do
        printf '  [%d] %s\n' "$((i + 1))" "$(basename "${repositorios_locales[$i]}")"
      done
      echo "  [m] Escribir otra ruta"
      read -r -p "Selecciona el repositorio [1]: " selection
      selection="${selection:-1}"
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#repositorios_locales[@]}" ]; then
        project_local_nuevo="${repositorios_locales[$((selection - 1))]}"
      elif [ "$selection" = "m" ] || [ "$selection" = "M" ]; then
        read -r -p "Ruta del proyecto en esta Mac: " project_local_nuevo
      elif [ -d "$selection" ]; then
        project_local_nuevo="$selection"
      else
        echo "Error: selección de repositorio no válida." >&2; exit 1
      fi
    else
      echo "  No se encontraron repositorios; introduce una ruta manual."
      read -r -p "Ruta del proyecto en esta Mac: " project_local_nuevo
    fi
    [ -d "$project_local_nuevo" ] || { echo "Error: no existe '$project_local_nuevo'." >&2; exit 1; }
    project_local_nuevo="$(cd "$project_local_nuevo" && pwd -P)"
    default_repository="$(basename "$project_local_nuevo")"
    detected_technology="$($ROOT/tools/vms/detectar_tecnologias_repositorio.sh "$project_local_nuevo" module)"
    project_git_url_nuevo="$(git -C "$project_local_nuevo" remote get-url origin 2>/dev/null || true)"
    project_git_branch_nuevo="$(git -C "$project_local_nuevo" branch --show-current 2>/dev/null || echo "main")"
  else
    read -r -p "URL Git del proyecto: " project_git_url_nuevo
    read -r -p "Rama Git del proyecto (main): " project_git_branch_nuevo
    project_git_branch_nuevo="${project_git_branch_nuevo:-main}"
    [ -n "$project_git_url_nuevo" ] || { echo "Error: URL Git obligatoria." >&2; exit 1; }
    default_repository="$(basename "${project_git_url_nuevo%.git}")"
  fi


  stack_default="backend"
  if [ -n "$detected_technology" ] && jq -e '
    ([.technologies[] | select(test("^(Vue|React|Next\\.js|Nuxt)"))] | length) > 0 and
    ([.technologies[] | select(test("^(PHP|Laravel|Illuminate)"))] | length) == 0
  ' <<< "$detected_technology" >/dev/null; then
    stack_default="frontend"
  fi
  read -r -p "Stack [backend/frontend] ($stack_default): " stack_nuevo
  stack_nuevo="${stack_nuevo:-$stack_default}"
  [ "$stack_nuevo" = "backend" ] || [ "$stack_nuevo" = "frontend" ] || { echo "Error: stack no soportado." >&2; exit 1; }
  workspace_default="/home/$user_nuevo/$default_repository"

  read -r -p "ID del repositorio ($default_repository): " repository_id_nuevo
  repository_id_nuevo="${repository_id_nuevo:-$default_repository}"
  read -r -p "Nombre del módulo ($repository_id_nuevo): " module_nuevo
  module_nuevo="${module_nuevo:-$repository_id_nuevo}"
  if [ "$stack_nuevo" = "backend" ]; then
    read -r -p "Tipo de repositorio [core/module] (module): " repository_kind_nuevo
    repository_kind_nuevo="${repository_kind_nuevo:-module}"
    [ "$repository_kind_nuevo" = "core" ] || [ "$repository_kind_nuevo" = "module" ] || { echo "Error: tipo backend no soportado." >&2; exit 1; }
  else
    repository_kind_nuevo="frontend"
  fi
  read -r -p "Alias para enrutamiento, separados por coma ($repository_id_nuevo,$module_nuevo): " aliases_nuevo
  aliases_nuevo="${aliases_nuevo:-$repository_id_nuevo,$module_nuevo}"
  [[ "$repository_id_nuevo" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$module_nuevo" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "Error: ID de repositorio o módulo no válido." >&2; exit 1;
  }
  aliases_json="$(printf '%s' "$aliases_nuevo" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
  if [ "$source_mode_nuevo" = "local" ]; then
    detected_technology="$($ROOT/tools/vms/detectar_tecnologias_repositorio.sh "$project_local_nuevo" "$repository_kind_nuevo")"
    echo "✓ Tecnologías detectadas: $(jq -r 'if (.technologies | length) == 0 then "ninguna" else .technologies | join(", ") end' <<< "$detected_technology")"
  fi

  local agentes_disponibles=()
  local i=1
  local default_agent_name="dev-back"
  local default_index=1
  [ "$stack_nuevo" = "backend" ] || default_agent_name="dev-front"

  echo ""
  echo "🤖 Agentes disponibles en skills/:"
  for s in "$ROOT/skills"/*; do
    if [ -d "$s" ] && [ -f "$s/SKILL.md" ]; then
      local name="$(basename "$s")"
      agentes_disponibles+=("$name")
      if [ "$name" = "$default_agent_name" ]; then
        default_index=$i
      fi
      printf '  [%d] %s\n' "$i" "$name"
      i=$((i+1))
    fi
  done

  echo ""
  read -r -p "Selecciona el agente [1-${#agentes_disponibles[@]}] ($default_index - $default_agent_name): " seleccion_agente
  local agente_elegido="$default_agent_name"


  if [ -n "${seleccion_agente:-}" ]; then
    if [[ "$seleccion_agente" =~ ^[0-9]+$ ]] && [ "$seleccion_agente" -ge 1 ] && [ "$seleccion_agente" -le "${#agentes_disponibles[@]}" ]; then
      agente_elegido="${agentes_disponibles[$((seleccion_agente-1))]}"
    elif [ -d "$ROOT/skills/$seleccion_agente" ]; then
      agente_elegido="$seleccion_agente"
    else
      echo "Error: el agente '$seleccion_agente' no existe en skills/." >&2; exit 1;
    fi
  fi


  local_agent_nuevo="skills/$agente_elegido"
  git_agent_path_nuevo="skills/$agente_elegido"
  remote_agent_nuevo="/home/$user_nuevo/agentes/$agente_elegido"
  echo "✓ Agente asignado a la VM: $agente_elegido ($local_agent_nuevo)"
  echo ""

  read -r -p "Workspace remoto ($workspace_default): " workspace_nuevo
  workspace_nuevo="${workspace_nuevo:-$workspace_default}"

  read -r -p "Actualización del agente [git/local] (git): " agent_update_mode_nuevo
  agent_update_mode_nuevo="${agent_update_mode_nuevo:-git}"
  [ "$agent_update_mode_nuevo" = "git" ] || [ "$agent_update_mode_nuevo" = "local" ] || { echo "Error: actualización no válida." >&2; exit 1; }

  git_url_nuevo=""
  git_branch_nuevo=""
  poll_nuevo="30"
  if [ "$agent_update_mode_nuevo" = "git" ]; then
    git_url_nuevo="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
    [[ "$git_url_nuevo" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || git_url_nuevo="https://github.com/CarlosPull/prueba_agentes.git"
    git_branch_default="$(git -C "$ROOT" branch --show-current)"
    read -r -p "Repositorio Git de agentes ($git_url_nuevo): " respuesta
    git_url_nuevo="${respuesta:-$git_url_nuevo}"
    read -r -p "Rama de agentes ($git_branch_default): " git_branch_nuevo
    git_branch_nuevo="${git_branch_nuevo:-$git_branch_default}"
    read -r -p "Intervalo del agente [10/15/20/30/60] (30): " poll_nuevo
    poll_nuevo="${poll_nuevo:-30}"
    [[ "$git_url_nuevo" =~ ^https://github\.com/[A-Za-z0-9._/-]+\.git$ ]] || { echo "Error: repositorio de agentes no válido." >&2; exit 1; }
    [[ "$git_branch_nuevo" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Error: rama de agentes no válida." >&2; exit 1; }
    case "$poll_nuevo" in 10|15|20|30|60) ;; *) echo "Error: intervalo no permitido." >&2; exit 1 ;; esac
  fi

  read -r -p "Versión de Node (24.19.0): " node_version_nuevo
  node_version_nuevo="${node_version_nuevo:-24.19.0}"
  read -r -p "Versión de Pi (latest): " pi_version_nuevo
  pi_version_nuevo="${pi_version_nuevo:-latest}"
  [[ "$node_version_nuevo" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: Node no válido." >&2; exit 1; }
  [[ "$pi_version_nuevo" = "latest" || "$pi_version_nuevo" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Error: Pi no válido." >&2; exit 1; }

  php_version_nuevo=""
  php_min_version_nuevo=""
  if [ "$stack_nuevo" = "backend" ]; then
    read -r -p "Versión PHP (8.4): " php_version_nuevo
    php_version_nuevo="${php_version_nuevo:-8.4}"
    read -r -p "Versión PHP mínima (8.4.1): " php_min_version_nuevo
    php_min_version_nuevo="${php_min_version_nuevo:-8.4.1}"
  fi

  echo ""
  echo "🔐 Configuración de Memoria Contextual mTLS (Memory Gateway):"
  read -r -p "¿Deseas habilitar Memory Gateway (mTLS) para esta VM? [s/N]: " enable_memory_ans
  memory_enabled_nuevo=false
  memory_gateway_url_nuevo="https://192.168.50.61:9443"
  memory_core_id_nuevo="$repository_id_nuevo"
  memory_tenant_id_nuevo="empresa-prueba"

  case "${enable_memory_ans:-n}" in
    s|S|si|Si|SI|y|Y|yes|Yes)
      memory_enabled_nuevo=true
      read -r -p "URL del Memory Gateway ($memory_gateway_url_nuevo): " ans_url
      memory_gateway_url_nuevo="${ans_url:-$memory_gateway_url_nuevo}"
      read -r -p "Core ID del Memory Gateway ($memory_core_id_nuevo): " ans_core
      memory_core_id_nuevo="${ans_core:-$memory_core_id_nuevo}"
      read -r -p "Tenant ID del Memory Gateway ($memory_tenant_id_nuevo): " ans_tenant
      memory_tenant_id_nuevo="${ans_tenant:-$memory_tenant_id_nuevo}"
      echo "✓ Memory Gateway mTLS habilitado."
      ;;
    *)
      echo "✓ Memory Gateway mTLS deshabilitado."
      ;;
  esac

  technology_tmp=""

  technology_action=""
  if [ "$source_mode_nuevo" = "local" ]; then
    private_parent="${PRIVATE_TECH_MEMORY%/*}"
    [ "$private_parent" != "$PRIVATE_TECH_MEMORY" ] || private_parent="."
    [ "$private_parent" = "." ] || install -d -m 0700 "$private_parent"
    if [ -s "$PRIVATE_TECH_MEMORY" ]; then
      jq -e '.version == 1 and (.repositories | type == "object")' "$PRIVATE_TECH_MEMORY" >/dev/null || {
        echo "Error: inventario tecnológico privado inválido: $PRIVATE_TECH_MEMORY" >&2; exit 1;
      }
      if jq -e --arg repository "$repository_id_nuevo" '.repositories | has($repository)' "$PRIVATE_TECH_MEMORY" >/dev/null; then
        technology_action="preservada"
      else
        technology_tmp="$(mktemp "$PRIVATE_TECH_MEMORY.XXXXXX")"
        jq --arg repository "$repository_id_nuevo" --argjson technology "$detected_technology" \
          '.repositories[$repository] = $technology' "$PRIVATE_TECH_MEMORY" > "$technology_tmp"
        technology_action="detectada"
      fi
    else
      technology_tmp="$(mktemp "$PRIVATE_TECH_MEMORY.XXXXXX")"
      jq -n --arg repository "$repository_id_nuevo" --argjson technology "$detected_technology" \
        '{version:1,repositories:{($repository):$technology}}' > "$technology_tmp"
      technology_action="detectada"
    fi
    [ -z "$technology_tmp" ] || chmod 0600 "$technology_tmp"
  fi

  config_tmp="$(mktemp "$VMS_CONF.nuevo.XXXXXX")"
  trap 'rm -f "$config_tmp"; [ -z "$technology_tmp" ] || rm -f "$technology_tmp"' EXIT INT TERM
  jq \
    --arg profile "$VM_PROFILE" --arg ip "$ip_nuevo" --arg user "$user_nuevo" \
    --arg workspace "$workspace_nuevo" --arg stack "$stack_nuevo" \
    --arg source_mode "$source_mode_nuevo" --arg agent_update_mode "$agent_update_mode_nuevo" \
    --arg project_local_path "$project_local_nuevo" --arg project_git_url "$project_git_url_nuevo" \
    --arg project_git_branch "$project_git_branch_nuevo" --arg node_version "$node_version_nuevo" \
    --arg pi_version "$pi_version_nuevo" --arg php_version "$php_version_nuevo" \
    --arg php_min_version "$php_min_version_nuevo" --arg local_agent "$local_agent_nuevo" \
    --arg remote_agent "$remote_agent_nuevo" --arg git_url "$git_url_nuevo" \
    --arg git_branch "$git_branch_nuevo" --arg git_agent_path "$git_agent_path_nuevo" \
    --arg agent_poll_seconds "$poll_nuevo" --arg repository_id "$repository_id_nuevo" \
    --arg module "$module_nuevo" --arg repository_kind "$repository_kind_nuevo" --argjson aliases "$aliases_json" \
    --arg memory_enabled "$memory_enabled_nuevo" --arg memory_gateway_url "$memory_gateway_url_nuevo" \
    --arg memory_core_id "$memory_core_id_nuevo" --arg memory_tenant_id "$memory_tenant_id_nuevo" '
      .[$profile] = {
        ip:$ip, user:$user, workspace:$workspace, stack:$stack,
        repositories:[{
          id:$repository_id, module:$module, kind:$repository_kind, path:$workspace,
          business_memory:("/home/" + $user + "/.local/share/prueba-agentes/business/" + $repository_id + ".md"),
          aliases:$aliases
        }],
        engine:"pi", dispatch_enabled:false,
        pi_harness:("/home/" + $user + "/.local/bin/pi-harness"),
        pi_provider:"openai-codex", pi_model:"gpt-5.4-mini",
        memory:{
          enabled:($memory_enabled == "true"),
          gateway_url:$memory_gateway_url,
          core_id:$memory_core_id,
          tenant_id:$memory_tenant_id,
          read_business:($memory_enabled == "true"),
          read_company:false,
          tls_key:("/home/" + $user + "/.config/prueba-agentes/memory-gateway/client.key"),
          tls_cert:("/home/" + $user + "/.config/prueba-agentes/memory-gateway/client.crt"),
          tls_ca:("/home/" + $user + "/.config/prueba-agentes/memory-gateway/ca.crt")
        },
        source_mode:$source_mode, agent_update_mode:$agent_update_mode,
        node_version:$node_version, pi_version:$pi_version,
        install_dependencies:($repository_kind != "module"), local_agent:$local_agent,
        remote_agent:$remote_agent
      }
      | if $source_mode == "local" then .[$profile].project_local_path = $project_local_path
        else .[$profile].project_git_url = $project_git_url | .[$profile].project_git_branch = $project_git_branch end
      | if $stack == "backend" then .[$profile].php_version = $php_version | .[$profile].php_min_version = $php_min_version else . end
      | if $agent_update_mode == "git" then
          .[$profile].git_url = $git_url |
          .[$profile].git_branch = $git_branch |
          .[$profile].git_agent_path = $git_agent_path |
          .[$profile].agent_poll_seconds = ($agent_poll_seconds | tonumber)
        else . end
    ' "$VMS_CONF" > "$config_tmp"

  chmod --reference="$VMS_CONF" "$config_tmp" 2>/dev/null || chmod 0644 "$config_tmp"
  [ -z "$technology_tmp" ] || mv "$technology_tmp" "$PRIVATE_TECH_MEMORY"
  mv "$config_tmp" "$VMS_CONF"
  trap - EXIT INT TERM
  echo "✓ Perfil '$VM_PROFILE' guardado en $VMS_CONF."
  if [ -n "$technology_action" ]; then
    echo "✓ Tecnología $technology_action en $PRIVATE_TECH_MEMORY."
    if [ "$(jq '.technologies | length' <<< "$detected_technology")" -eq 0 ] && [ "$technology_action" = "detectada" ]; then
      echo "  Aviso: no se encontraron manifiestos compatibles; completa manualmente la entrada '$repository_id_nuevo'." >&2
    fi
  else
    echo "ℹ️ Origen Git: no hay una copia local que inspeccionar; registra la tecnología cuando el repositorio esté disponible localmente."
  fi
}

if ! jq -e --arg profile "$VM_PROFILE" '(.[$profile] | type) == "object"' "$VMS_CONF" >/dev/null; then
  CONFIGURAR_PERFIL_NUEVO
fi

if [ "$OPCION" = "--solo-configurar" ]; then
  jq --arg profile "$VM_PROFILE" '.[$profile]' "$VMS_CONF"
  exit 0
fi
for archivo in "$BOOTSTRAP_LOCAL" "$APPARMOR_BWRAP_LOCAL" "$HARNESS_LOCAL/bin/pi-harness" "$HARNESS_LOCAL/bin/filtrar_salida_pi.sh" "$HARNESS_LOCAL/extension/index.ts"; do
  [ -s "$archivo" ] || { echo "Error: falta el recurso local '$archivo'." >&2; exit 1; }
done

GET_VM_FIELD() {
  local field="$1"
  jq -r --arg profile "$VM_PROFILE" --arg field "$field" \
    'if (.[$profile] | type) == "object" and (.[$profile] | has($field)) then .[$profile][$field] else empty end' \
    "$VMS_CONF" 2>/dev/null || true
}

ip="$(GET_VM_FIELD ip)"
user="$(GET_VM_FIELD user)"
workspace="$(GET_VM_FIELD workspace)"
stack="$(GET_VM_FIELD stack)"
source_mode="$(GET_VM_FIELD source_mode)"
[ -n "$source_mode" ] || source_mode="git"
agent_update_mode="$(GET_VM_FIELD agent_update_mode)"
[ -n "$agent_update_mode" ] || agent_update_mode="git"
project_local_path="$(GET_VM_FIELD project_local_path)"
project_git_url="$(GET_VM_FIELD project_git_url)"
project_git_branch="$(GET_VM_FIELD project_git_branch)"
node_version="$(GET_VM_FIELD node_version)"
pi_version="$(GET_VM_FIELD pi_version)"
[ -n "$pi_version" ] || pi_version="latest"
php_version="$(GET_VM_FIELD php_version)"
php_min_version="$(GET_VM_FIELD php_min_version)"
install_dependencies="$(GET_VM_FIELD install_dependencies)"
project_kind="$(jq -r --arg profile "$VM_PROFILE" '.[$profile].repositories[0].kind // empty' "$VMS_CONF")"
local_agent="$(GET_VM_FIELD local_agent)"
remote_agent="$(GET_VM_FIELD remote_agent)"
agent_git_url="$(GET_VM_FIELD git_url)"
agent_git_branch="$(GET_VM_FIELD git_branch)"
agent_git_path="$(GET_VM_FIELD git_agent_path)"
agent_poll_seconds="$(GET_VM_FIELD agent_poll_seconds)"
remote_harness="/home/$user/.local/lib/prueba-agentes/pi-harness"
remote_pi_harness="/home/$user/.local/bin/pi-harness"

for valor in "$ip" "$user" "$workspace" "$stack" "$node_version" "$install_dependencies" "$remote_agent"; do
  [ -n "$valor" ] || { echo "Error: configuración incompleta para '$VM_PROFILE' en vms.json." >&2; exit 1; }
done
[ "$project_kind" = "core" ] || [ "$project_kind" = "module" ] || [ "$project_kind" = "frontend" ] || {
  echo "Error: el repositorio principal de '$VM_PROFILE' debe declarar kind core, module o frontend." >&2; exit 1;
}
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] || {
  echo "Error: usuario o dirección SSH no válidos para '$VM_PROFILE'." >&2
  exit 1
}
[[ "$workspace" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] || {
  echo "Error: workspace debe permanecer dentro de /home/<usuario>." >&2
  exit 1
}
[ "$stack" = "backend" ] || [ "$stack" = "frontend" ] || {
  echo "Error: stack no soportado para '$VM_PROFILE': '$stack'." >&2
  exit 1
}
[ "$source_mode" = "git" ] || [ "$source_mode" = "local" ] || {
  echo "Error: source_mode debe ser 'git' o 'local'." >&2
  exit 1
}
[ "$agent_update_mode" = "git" ] || [ "$agent_update_mode" = "local" ] || {
  echo "Error: agent_update_mode debe ser 'git' o 'local'." >&2
  exit 1
}
[[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: node_version no válido." >&2; exit 1; }
[[ "$pi_version" = "latest" || "$pi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "Error: pi_version debe ser 'latest' o una versión semántica." >&2
  exit 1
}
[ "$install_dependencies" = "true" ] || [ "$install_dependencies" = "false" ] || {
  echo "Error: install_dependencies debe ser true o false." >&2
  exit 1
}

if [ "$stack" = "backend" ]; then
  [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] && [[ "$php_min_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Error: php_version o php_min_version no son válidos." >&2
    exit 1
  }
  [ -s "$PAQUETES_BACKEND_LOCAL" ] || { echo "Error: falta el instalador de paquetes backend." >&2; exit 1; }
fi

if [ "$source_mode" = "git" ]; then
  for valor in "$project_git_url" "$project_git_branch"; do
    [ -n "$valor" ] || { echo "Error: configuración Git del proyecto incompleta." >&2; exit 1; }
  done
else
  [ -d "$project_local_path" ] || { echo "Error: no existe el proyecto local '$project_local_path'." >&2; exit 1; }
  if [ "$stack" = "backend" ]; then
    [ -s "$project_local_path/composer.json" ] || { echo "Error: '$project_local_path' no contiene composer.json." >&2; exit 1; }
    [ "$project_kind" != "core" ] || [ -s "$project_local_path/artisan" ] || { echo "Error: el core '$project_local_path' no contiene artisan." >&2; exit 1; }
  else
    [ -s "$project_local_path/package.json" ] || { echo "Error: el proyecto frontend no contiene package.json." >&2; exit 1; }
  fi
fi

if [ "$agent_update_mode" = "git" ]; then
  for valor in "$agent_git_url" "$agent_git_branch" "$agent_git_path" "$agent_poll_seconds"; do
    [ -n "$valor" ] || { echo "Error: configuración Git del agente incompleta." >&2; exit 1; }
  done
else
  [ -s "$ROOT/$local_agent/SKILL.md" ] || { echo "Error: el agente local no contiene SKILL.md." >&2; exit 1; }
fi

target="$user@$ip"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")

if ! ssh "${SSH_OPTS[@]}" "$target" "echo OK" >/dev/null 2>&1; then
  echo "🔑 Configurando acceso SSH sin contraseña hacia '$target'..."
  "$ROOT/tools/vms/configurar_ssh_vm.sh" "$target"
fi

if [ "$OPCION" = "--con-sudo-interactivo" ]; then
  paquetes=(git curl ca-certificates cron jq tar rsync util-linux bubblewrap apparmor build-essential locales software-properties-common)
  remote_apparmor_profile="/home/$user/.local/lib/prueba-agentes/prueba-agentes-bwrap.apparmor"
  ssh "${SSH_OPTS[@]}" "$target" \
    "mkdir -p '/home/$user/.local/lib/prueba-agentes' && install -m 0644 /dev/stdin '$remote_apparmor_profile.nuevo' && mv -f '$remote_apparmor_profile.nuevo' '$remote_apparmor_profile'" \
    < "$APPARMOR_BWRAP_LOCAL"
  configurar_apparmor="if [ -s /etc/apparmor.d/bwrap-userns-restrict ]; then
    if [ -s /etc/apparmor.d/prueba-agentes-bwrap ]; then
      sudo apparmor_parser -R /etc/apparmor.d/prueba-agentes-bwrap 2>/dev/null || true;
      sudo rm -f /etc/apparmor.d/prueba-agentes-bwrap;
    fi;
    sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict;
  else
    sudo install -m 0644 '$remote_apparmor_profile' /etc/apparmor.d/prueba-agentes-bwrap;
    sudo apparmor_parser -r /etc/apparmor.d/prueba-agentes-bwrap;
  fi"
  if [ "$stack" = "backend" ]; then
    remote_package_installer="/home/$user/.local/lib/prueba-agentes/instalar_paquetes_backend.sh"
    ssh "${SSH_OPTS[@]}" "$target" \
      "mkdir -p '/home/$user/.local/lib/prueba-agentes' && install -m 0755 /dev/stdin '$remote_package_installer.nuevo' && mv -f '$remote_package_installer.nuevo' '$remote_package_installer'" \
      < "$PAQUETES_BACKEND_LOCAL"
    echo "📦 Instalando sistema, Bubblewrap y PHP $php_version en '$target'..."
    ssh -tt "${SSH_OPTS[@]}" "$target" \
      "'$remote_package_installer' '$php_version' '$php_min_version' ${paquetes[*]} && $configurar_apparmor"
  else
    echo "📦 Instalando sistema y Bubblewrap en '$target'..."
    ssh -tt "${SSH_OPTS[@]}" "$target" \
      "export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo apt-get update && sudo apt-get install -y ${paquetes[*]} && sudo systemctl enable --now cron && $configurar_apparmor"
  fi
fi

remote_bootstrap="/home/$user/.local/lib/prueba-agentes/provisionar_vm_pi.sh"
ssh "${SSH_OPTS[@]}" "$target" \
  "mkdir -p '/home/$user/.local/lib/prueba-agentes' && install -m 0755 /dev/stdin '$remote_bootstrap.nuevo' && mv -f '$remote_bootstrap.nuevo' '$remote_bootstrap'" \
  < "$BOOTSTRAP_LOCAL"

modo="provisionar"
[ "$OPCION" != "--solo-verificar" ] || modo="verificar"

if [ "$modo" = "provisionar" ]; then
  echo "📤 Instalando pi-harness en '$target:$remote_harness'..."
  ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$remote_harness' '/home/$user/.local/bin'"
  rsync -az --delete --exclude='.git/' "$HARNESS_LOCAL/" "$target:$remote_harness/"
  ssh "${SSH_OPTS[@]}" "$target" \
    "chmod 0755 '$remote_harness/bin/pi-harness' '$remote_harness/bin/filtrar_salida_pi.sh' && ln -sfn '$remote_harness/bin/pi-harness' '$remote_pi_harness'"

  if [ "$source_mode" = "local" ]; then
    echo "📤 Copiando proyecto local a '$target:$workspace'..."
    ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$workspace'"
    # El proyecto local es la fuente autoritativa. --delete elimina residuos de
    # versiones anteriores, pero los directorios/archivos excluidos se conservan.
    rsync -az --delete --exclude='.git/' --exclude='vendor/' --exclude='node_modules/' --exclude='.env' \
      "$project_local_path/" "$target:$workspace/"
  fi

  if [ "$agent_update_mode" = "local" ]; then
    version_local="local-$(date +%Y%m%d%H%M%S)"
    version_dir="$remote_agent/.versiones/$version_local"
    echo "📤 Copiando agente local '$stack'..."
    ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$version_dir'"
    rsync -az --exclude='.git/' "$ROOT/$local_agent/" "$target:$version_dir/"
    ssh "${SSH_OPTS[@]}" "$target" \
      "test -s '$version_dir/SKILL.md' && printf '%s\n' '$version_local' > '$version_dir/.agent-version' && printf '%s\n' local > '$version_dir/.git-commit' && ln -sfn '.versiones/$version_local' '$remote_agent/actual.nuevo' && mv -Tf '$remote_agent/actual.nuevo' '$remote_agent/actual'"
  fi
fi

ENVIAR_CONFIG() {
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$VM_PROFILE" "$stack" "$project_kind" "$source_mode" "$agent_update_mode" "$workspace" \
    "$project_git_url" "$project_git_branch" "$node_version" "$pi_version" \
    "$php_min_version" "$install_dependencies" "$remote_agent" "$agent_git_url" \
    "$agent_git_branch" "$agent_git_path" "$agent_poll_seconds" "$remote_harness" \
    "$remote_pi_harness" "${GITHUB_TOKEN:-}"
}

# Asegurar llaves SSH e identidad Git en la VM antes del bootstrap remoto
"$ROOT/tools/vms/configurar_git_vms.sh" "$VM_PROFILE" || true

if ENVIAR_CONFIG | ssh "${SSH_OPTS[@]}" "$target" "'$remote_bootstrap' '$modo'"; then

  :
else
  codigo=$?
  if [ "$codigo" -eq 20 ] && [ "$OPCION" != "--con-sudo-interactivo" ]; then
    echo "Reintenta con: ./tools/vms/provisionar_vm_pi.sh $VM_PROFILE --con-sudo-interactivo" >&2
  fi
  exit "$codigo"
fi

[ "$modo" != "verificar" ] || exit 0

if [ "$agent_update_mode" = "git" ]; then
  "$ROOT/tools/sincronizacion/instalar_actualizacion_git.sh" "$VM_PROFILE"
else
  echo "✓ Agente instalado desde la Mac; no se configura cron Git."
fi

ENVIAR_CONFIG | ssh "${SSH_OPTS[@]}" "$target" "'$remote_bootstrap' verificar"
"$ROOT/tools/vms/inicializar_memorias_negocio_vm.sh" "$VM_PROFILE"
[ "$agent_update_mode" != "local" ] || "$ROOT/tools/sincronizacion/instalar_monitor_local.sh"

if [ "$(jq -r --arg p "$VM_PROFILE" '.[$p].memory.enabled // false' "$VMS_CONF")" = "true" ]; then
  "$ROOT/tools/vms/sincronizar_mtls_vm.sh" "$VM_PROFILE" || true
fi
"$ROOT/tools/vms/configurar_git_vms.sh" "$VM_PROFILE" || true


# Solo se habilita este perfil después de una verificación correcta. Pueden
# coexistir varias VMs backend; el analista elige perfil y repositorio.
config_tmp="$(mktemp "$VMS_CONF.activar.XXXXXX")"
jq --arg profile "$VM_PROFILE" '
  .[$profile].engine = "pi"
  | .[$profile].dispatch_enabled = true
  | .[$profile].pi_harness = ("/home/" + .[$profile].user + "/.local/bin/pi-harness")
  | .[$profile].pi_provider = (.[$profile].pi_provider // "openai-codex")
  | .[$profile].pi_model = (.[$profile].pi_model // "gpt-5.4-mini")
' "$VMS_CONF" > "$config_tmp"
chmod --reference="$VMS_CONF" "$config_tmp" 2>/dev/null || chmod 0644 "$config_tmp"
mv "$config_tmp" "$VMS_CONF"

echo "✅ VM '$VM_PROFILE' preparada con Pi, pi-harness y agente '$stack'."
echo "ℹ️ agent-runner y OpenCode no fueron instalados por este script."
