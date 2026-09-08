#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/vms/lib_vms.sh"
CONFIG="$ROOT/config/vms.json"

jq -e '
  all(to_entries[] | select((.value.repositories // []) | length > 0);
    (.value.user | type) == "string"
    and all(.value.repositories[]; has("id") and has("stack") and has("path"))
    and all(.value.users[]?.repositories[]?;
      ((keys - ["id","repository","can_read","can_write"]) | length) == 0))
' "$CONFIG" >/dev/null

[ "$(VMS_FIELD "$CONFIG" VM1 user)" = carlos ]
[ "$(VMS_FIELD "$CONFIG" VM1 stack)" = backend ]
repos="$(VMS_USER_REPOSITORIES_JSON "$CONFIG" VM1 carlos)"
jq -e 'length == 1 and .[0].id == "api-monolitic-comments"
  and .[0].can_read == true and .[0].can_write == true
  and .[0].dispatch_enabled == true' <<< "$repos" >/dev/null

# Un nuevo usuario agrega solamente un grant; la definición técnica no se copia.
temp="$(mktemp "${TMPDIR:-/tmp}/vms-normalizada.XXXXXX")"
trap 'rm -f "$temp" "${temp}.error"; rmdir "${temp}.proyecto" 2>/dev/null || true' EXIT
jq '.VM1.users += [{name:"analista",repositories:[{id:"api-monolitic-comments",can_read:true,can_write:false}]}]' "$CONFIG" > "$temp"
[ "$(VMS_USER_REPOSITORIES_JSON "$temp" VM1 analista | jq -r '.[0].project_git_url')" = "https://github.com/Felix-Pull/api-monolitic-comments.git" ]
[ "$(VMS_USER_REPOSITORIES_JSON "$temp" VM1 analista | jq -r '.[0].can_write')" = false ]
[ "$(grep -c 'api-monolitic-comments.git' "$temp")" -eq 1 ]
jq -e 'length == 1 and .[0].id == "api-monolitic-comments"' \
  <<< "$(VMS_USER_REPOSITORIES_JSON "$temp" VM1 "")" >/dev/null

mkdir "${temp}.proyecto"
if PRUEBA_AGENTES_VMS_CONF="$temp" "$ROOT/tools/despacho/despachar_vm.sh" backend "${temp}.proyecto" \
  "intenta modificar" --profile VM1 --repository api-monolitic-comments --usuario analista 2>"${temp}.error"; then
  echo "FALLO: un grant de solo lectura permitió escritura." >&2
  exit 1
fi
grep -F 'no tiene permiso de escritura' "${temp}.error" >/dev/null
rm -f "${temp}.error"
rmdir "${temp}.proyecto"

echo "OK: definiciones técnicas únicas y grants normalizados verificados."
