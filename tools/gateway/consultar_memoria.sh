#!/usr/bin/env bash
# Explorador CLI de la Memoria Compartida y Contratos del Memory Gateway
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_PATH="$ROOT/.private/memory-gateway-data/gateway.sqlite"

USO() {
  echo "🤖 CLI de Consulta de Memoria - Memory Gateway"
  echo "-----------------------------------------------"
  echo "Uso: ./tools/gateway/consultar_memoria.sh [opciones]"
  echo ""
  echo "Opciones:"
  echo "  --contratos              Listar todos los contratos JSON de endpoints registrados"
  echo "  --empresa                Listar las reglas de la memoria corporativa (capa company)"
  echo "  --buscar <palabra>       Buscar contratos o memorias por palabra clave"
  echo "  --ver <metodo> <ruta>    Ver el esquema JSON completo de un contrato específico"
  echo "  --ayuda                  Mostrar este mensaje de ayuda"
  echo ""
}

[ -f "$DB_PATH" ] || {
  echo "Error: No se encontró la base de datos del Memory Gateway en '$DB_PATH'." >&2
  exit 1
}

# Si no se pasan argumentos, mostrar resumen de la memoria
if [ $# -eq 0 ]; then
  echo "🧠 Estado de la Memoria del Memory Gateway"
  echo "=========================================="
  echo ""
  total_contratos="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM contracts;")"
  total_empresa="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM private_memories WHERE layer='company';")"
  
  echo "  📊 Contratos de Endpoints Registrados : $total_contratos"
  echo "  🏢 Reglas de Memoria Corporativa (Company): $total_empresa"
  echo ""
  echo "Comandos rápidos disponibles:"
  echo "  ./tools/gateway/consultar_memoria.sh --contratos"
  echo "  ./tools/gateway/consultar_memoria.sh --empresa"
  echo "  ./tools/gateway/consultar_memoria.sh --buscar <termino>"
  exit 0
fi

OPCION="${1:-}"
case "$OPCION" in
  --contratos)
    echo "📋 Contratos de Endpoints Registrados en SQLite:"
    echo "---------------------------------------------------------------------------------------------------"
    printf "%-8s %-32s %-22s %-12s %-8s\n" "MÉTODO" "PATH" "REPOSITORIO" "MÓDULO" "REVISIÓN"
    echo "---------------------------------------------------------------------------------------------------"
    sqlite3 -separator '|' "$DB_PATH" "SELECT method, path, repository, module, revision FROM contracts ORDER BY repository, path;" | while IFS='|' read -r method path repo mod rev; do
      printf "%-8s %-32s %-22s %-12s %-8s\n" "$method" "$path" "$repo" "$mod" "v$rev"
    done
    echo "---------------------------------------------------------------------------------------------------"
    echo "💡 Usa '--ver <metodo> <ruta>' para inspeccionar el esquema JSON completo de un endpoint."
    ;;

  --empresa)
    echo "🏢 Reglas de la Memoria Corporativa (Capa Company):"
    echo "---------------------------------------------------------------------------------------------------"
    sqlite3 -separator '|' "$DB_PATH" "SELECT id, content, created_at FROM private_memories WHERE layer='company';" | while IFS='|' read -r id content created; do
      echo "📌 [ID: $id] (Registrado: $created)"
      echo "   $content"
      echo ""
    done
    ;;

  --buscar)
    QUERY="${2:-}"
    [ -n "$QUERY" ] || { echo "Error: especifica un término de búsqueda. Ej: --buscar stats" >&2; exit 1; }
    echo "🔍 Resultados de búsqueda para: '$QUERY'"
    echo "---------------------------------------------------------------------------------------------------"
    echo "📄 Contratos coincidentes:"
    sqlite3 -separator '|' "$DB_PATH" "SELECT method, path, repository, json_extract(document, '$.summary') FROM contracts WHERE path LIKE '%$QUERY%' OR document LIKE '%$QUERY%';" | while IFS='|' read -r method path repo summary; do
      echo "  • $method $path ($repo) - ${summary:-Sin descripción}"
    done
    echo ""
    echo "🏢 Reglas corporativas coincidentes:"
    sqlite3 -separator '|' "$DB_PATH" "SELECT content FROM private_memories WHERE layer='company' AND content LIKE '%$QUERY%';" | while IFS='|' read -r content; do
      echo "  • $content"
    done
    ;;

  --ver)
    METODO="${2:-}"
    RUTA="${3:-}"
    [ -n "$METODO" ] && [ -n "$RUTA" ] || { echo "Error: uso: --ver <METODO> <RUTA>. Ej: --ver GET /api/posts/{id}/stats" >&2; exit 1; }
    echo "📄 Esquema del Contrato para: $METODO $RUTA"
    echo "---------------------------------------------------------------------------------------------------"
    doc="$(sqlite3 "$DB_PATH" "SELECT document FROM contracts WHERE upper(method)=upper('$METODO') AND path='$RUTA';")"
    if [ -n "$doc" ]; then
      printf '%s\n' "$doc" | jq .
    else
      echo "No se encontró ningún contrato para '$METODO $RUTA'." >&2
      exit 1
    fi
    ;;

  --ayuda|-h)
    USO
    ;;

  *)
    echo "Error: Opción no reconocida '$OPCION'." >&2
    USO
    exit 1
    ;;
esac
