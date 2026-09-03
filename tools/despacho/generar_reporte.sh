#!/usr/bin/env bash
# Herramienta 4: Compilación y actualización en tiempo real de REPORTE_PI.md y EVIDENCIA_AGENTES.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq es obligatorio para generar reportes." >&2
  exit 1
}

PROJECT_DIR="${1:-}"
TAREA="${2:-}"
MODE="consolidar"
TARGET_DISPATCH=""

shift "$([ "$#" -ge 2 ] && echo 2 || echo 0)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inicializar) MODE="inicializar"; shift ;;
    --actualizar) MODE="actualizar"; TARGET_DISPATCH="${2:-}"; shift "$([ "$#" -ge 2 ] && echo 2 || echo 1)" ;;
    --consolidar) MODE="consolidar"; shift ;;
    *) shift ;;
  esac
done

if [ -z "$PROJECT_DIR" ] || [ -z "$TAREA" ]; then
  echo "Uso: ./tools/despacho/generar_reporte.sh <directorio_proyecto> \"Tarea\" [--inicializar | --actualizar <dispatch_id> | --consolidar]" >&2
  exit 1
fi

REPORT="$PROJECT_DIR/REPORTE_PI.md"
EVIDENCE="$PROJECT_DIR/EVIDENCIA_AGENTES.md"
DESPACHOS_FILE="$PROJECT_DIR/DESPACHOS.json"
REQUISITOS_FILE="$PROJECT_DIR/REQUISITOS.json"

GET_VM_FIELD() {
  local profile="$1"
  local field="$2"
  jq -er --arg profile "$profile" --arg field "$field" '.[$profile][$field]' "$VMS_CONF" 2>/dev/null || true
}

CONSOLIDAR_EVIDENCIAS() {
  {
    echo "# Evidencia de agentes Pi remotos utilizados"
    echo ""
    echo "Metadatos emitidos dentro de cada VM durante la ejecución por SSH."
    echo ""
    for evidence_file in "$PROJECT_DIR"/EVIDENCIA_*.md "$PROJECT_DIR"/.evidencia_*.tmp; do
      [ -f "$evidence_file" ] || continue
      [ "$evidence_file" != "$EVIDENCE" ] || continue
      [ ! -s "$evidence_file" ] || cat "$evidence_file"
    done
  } > "$EVIDENCE"
}

PROCESAR_LOG_DISPATCH() {
  local dispatch_id="$1"
  local log_file="$PROJECT_DIR/${dispatch_id}_output.log"

  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    printf 'EN_PROGRESO|*(En espera de ejecución...)*|'
    return
  fi

  if grep -q "RECHAZADO_ROL_INCORRECTO" "$log_file"; then
    local razon
    razon="$(grep "RECHAZADO_ROL_INCORRECTO" "$log_file" | head -n 1 | sed 's/.*RECHAZADO_ROL_INCORRECTO: //')"
    printf 'RECHAZADO|%s|' "Rechazado por el analista del agente: ${razon:-Rol no compatible.}"
    return
  fi

  if grep -qE "❌ TAREA RECHAZADA|Error:" "$log_file" && ! grep -q "Hecho" "$log_file"; then
    local err
    err="$(grep -E "❌|Error:" "$log_file" | head -n 1)"
    printf 'FALLIDO|%s|' "Falló la ejecución: ${err:-Error durante la ejecución en la VM.}"
    return
  fi

  # Archivos modificados/creados extraídos del log mediante expresiones regulares precisas
  local archivos
  archivos="$(grep -oE '`[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+`|\b(app|src|config|routes|database|public)/[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+\b' "$log_file" | tr -d '`' | sort -u | paste -sd ', ' - || true)"

  # Resumen de cambios reportados por el agente
  local resumen
  resumen="$(awk '/^(sandbox_backend|platform|PI_VERSION):/ {flag=1; next} flag {print}' "$log_file" | sed '/^[[:space:]]*$/d' | grep -v '^PERFIL' | grep -v '^AGENTE' | head -n 12 || cat "$log_file" | tail -n 10)"
  resumen="$(printf '%s' "$resumen" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

  printf 'COMPLETADO|%s|%s' "${resumen:-Ejecución finalizada correctamente.}" "${archivos:-Sin archivos modificados declarados}"
}

CONSTRUIR_REPORTE() {
  local total_dispatches=0
  local completados=0
  local rechazados=0
  local fallidos=0
  local en_progreso=0

  if [ -f "$DESPACHOS_FILE" ]; then
    total_dispatches="$(jq 'length' "$DESPACHOS_FILE")"
  elif [ -f "$REQUISITOS_FILE" ]; then
    total_dispatches="$(jq '[.requirements[] | select(.target_profile != null)] | length' "$REQUISITOS_FILE")"
  fi

  # Conteo de estados
  if [ "$total_dispatches" -gt 0 ] && [ -f "$DESPACHOS_FILE" ]; then
    while IFS= read -r dispatch_id; do
      [ -n "$dispatch_id" ] || continue
      local info
      info="$(PROCESAR_LOG_DISPATCH "$dispatch_id")"
      local st="${info%%|*}"
      case "$st" in
        COMPLETADO) completados=$((completados + 1)) ;;
        RECHAZADO) rechazados=$((rechazados + 1)) ;;
        FALLIDO) fallidos=$((fallidos + 1)) ;;
        *) en_progreso=$((en_progreso + 1)) ;;
      esac
    done < <(jq -r '.[].dispatch_id // .[].id' "$DESPACHOS_FILE")
  fi

  local estado_general=""
  if [ "$en_progreso" -gt 0 ] || [ "$total_dispatches" -eq 0 ]; then
    estado_general="⏳ EN PROGRESO ($completados/$total_dispatches completadas)"
  elif [ "$fallidos" -eq 0 ] && [ "$rechazados" -eq 0 ]; then
    estado_general="✅ FINALIZADO ($completados/$total_dispatches completadas exitosamente)"
  else
    estado_general="⚠️ FINALIZADO ($completados/$total_dispatches exitosas, $rechazados rechazadas, $fallidos fallidas)"
  fi

  {
    echo "# Informe de Ejecución Distribuida con Pi"
    echo ""
    echo "- **Solicitud original**: $TAREA"
    echo "- **Fecha de registro**: $(date)"
    echo "- **Estado General**: $estado_general"
    echo ""
    echo "---"
    echo ""
    echo "## Requisitos analizados y enrutados"
    echo ""
    if [ -f "$REQUISITOS_FILE" ]; then
      jq -r '.requirements[] | "- [\(.id)] **\(.category)**" + (if .target_profile then " → `\(.target_profile)/\(.repository)` (`\(.module)`)" else "" end) + ": \(.text)"' "$REQUISITOS_FILE"
    else
      echo "$TAREA"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## Estado de Ejecución por Destino (VM)"
    echo ""

    if [ -f "$DESPACHOS_FILE" ]; then
      local idx=0
      while IFS= read -r group_json; do
        idx=$((idx + 1))
        local d_id cat prof repo mod work
        d_id="$(jq -r '.dispatch_id' <<< "$group_json")"
        cat="$(jq -r '.category' <<< "$group_json")"
        prof="$(jq -r '.profile' <<< "$group_json")"
        repo="$(jq -r '.repository' <<< "$group_json")"
        mod="$(jq -r '.module' <<< "$group_json")"
        work="$(jq -r '.workspace' <<< "$group_json")"
        ip="$(GET_VM_FIELD "$prof" "ip")"

        local log_info st_code summary files
        log_info="$(PROCESAR_LOG_DISPATCH "$d_id")"
        st_code="$(echo "$log_info" | cut -d'|' -f1)"
        summary="$(echo "$log_info" | cut -d'|' -f2)"
        files="$(echo "$log_info" | cut -d'|' -f3)"

        local st_badge=""
        local check_mark="[ ]"
        case "$st_code" in
          COMPLETADO) st_badge="✅ COMPLETADO"; check_mark="[x]" ;;
          RECHAZADO)  st_badge="⚠️ RECHAZADO"; check_mark="[x]" ;;
          FALLIDO)    st_badge="❌ FALLIDO"; check_mark="[ ]" ;;
          *)          st_badge="⏳ EN PROGRESO"; check_mark="[ ]" ;;
        esac

        echo "### $idx. Rol: \`$cat\` (perfil: \`$prof\`, módulo: \`$mod\`, VM: \`${ip:-local}\`)"
        echo "- **Workspace**: \`$work\`"
        echo "- **Repositorio**: \`$repo\`"
        echo "- **Estado**: $st_badge"

        local log_file="$PROJECT_DIR/${d_id}_output.log"
        if [ -f "$log_file" ]; then
          local branch_pub commit_pub pr_url
          branch_pub="$(sed -n 's/^RAMA_PUBLICADA: //p' "$log_file" | head -n 1)"
          [ -n "$branch_pub" ] || branch_pub="$(sed -n 's/^RAMA_TAREA: //p' "$log_file" | head -n 1)"
          commit_pub="$(sed -n 's/^COMMIT_PUBLICADO: //p' "$log_file" | head -n 1)"
          pr_url="$(sed -n 's/^PULL_REQUEST_URL: //p' "$log_file" | head -n 1)"
          if [ -n "$branch_pub" ]; then
            echo "- **Rama Git de la Tarea**: \`$branch_pub\`"
            [ -z "$commit_pub" ] || echo "- **Commit Git Publicado**: \`$commit_pub\`"
            [ -z "$pr_url" ] || echo "- **Pull Request**: [$pr_url]($pr_url)"
          fi

        fi

        echo "- **Tareas asignadas**:"
        while IFS= read -r req_json; do
          [ -n "$req_json" ] || continue
          local req_id req_text
          req_id="$(jq -r '.id' <<< "$req_json")"
          req_text="$(jq -r '.text' <<< "$req_json")"
          echo "  - $check_mark **[$req_id]**: $req_text"
        done < <(jq -c '.requirements[]' <<< "$group_json")

        if [ "$st_code" = "COMPLETADO" ] || [ "$st_code" = "RECHAZADO" ] || [ "$st_code" = "FALLIDO" ]; then
          if [ -n "$files" ]; then
            echo "- **Archivos modificados/creados**:"
            IFS=',' read -ra ADDR <<< "$files"
            for f in "${ADDR[@]}"; do
              f_trimmed="$(echo "$f" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
              [ -n "$f_trimmed" ] && echo "  - \`$f_trimmed\`"
            done
          fi
          echo "- **Resultado del Agente**: $summary"
        else
          echo "- **Resultado del Agente**: *(En espera de ejecución por la VM...)*"
        fi
        echo ""
      done < <(jq -c '.[]' "$DESPACHOS_FILE")

    else
      # Si aún no existe DESPACHOS.json, iterar sobre bitácoras sueltas creadas
      for log_file in "$PROJECT_DIR"/*_output.log; do
        [ -f "$log_file" ] || continue
        local prof cat repo mod work ip
        prof="$(sed -n 's/^PERFIL_VM: //p; s/^PERFIL_VM_LOCAL: //p' "$log_file" | head -n 1)"
        cat="$(sed -n 's/^ROL: //p' "$log_file" | head -n 1)"
        repo="$(sed -n 's/^REPOSITORIO: //p' "$log_file" | head -n 1)"
        mod="$(sed -n 's/^MODULO: //p' "$log_file" | head -n 1)"
        work="$(sed -n 's/^WORKSPACE_REMOTO: //p' "$log_file" | head -n 1)"
        ip="$(GET_VM_FIELD "$prof" "ip")"
        local d_id="${log_file##*/}"
        d_id="${d_id%_output.log}"

        local log_info st_code summary files
        log_info="$(PROCESAR_LOG_DISPATCH "$d_id")"
        st_code="$(echo "$log_info" | cut -d'|' -f1)"
        summary="$(echo "$log_info" | cut -d'|' -f2)"
        files="$(echo "$log_info" | cut -d'|' -f3)"

        echo "### Rol: \`${cat:-n/d}\` (perfil: \`${prof:-n/d}\`, módulo: \`${mod:-n/d}\`, VM: \`${ip:-local}\`)"
        echo "- **Workspace**: \`${work:-n/d}\`"
        echo "- **Estado**: $st_code"
        if [ -n "$files" ]; then
          echo "- **Archivos modificados/creados**:"
          IFS=',' read -ra ADDR <<< "$files"
          for f in "${ADDR[@]}"; do
            f_trimmed="$(echo "$f" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -n "$f_trimmed" ] && echo "  - \`$f_trimmed\`"
          done
        fi
        echo "- **Resultado**: $summary"
        echo ""
      done
    fi
  } > "$REPORT"
}

CONSTRUIR_REPORTE
CONSOLIDAR_EVIDENCIAS

# En modo consolidar final, eliminar archivos intermediarios redundantes para mantener limpia la carpeta
if [ "$MODE" = "consolidar" ]; then
  rm -f "$PROJECT_DIR/REQUISITOS.md"
  for f in "$PROJECT_DIR"/EVIDENCIA_*.md; do
    [ "$f" != "$EVIDENCE" ] || continue
    rm -f "$f"
  done
  rm -f "$PROJECT_DIR"/.evidencia_*.tmp
fi

echo "📄 Reporte consolidado guardado en: $REPORT"
