#!/usr/bin/env bash
# Lecturas compatibles del inventario normalizado y del formato histórico.

VMS_REPOSITORIES_JSON() {
  local config="$1" profile="$2"
  jq -c --arg profile "$profile" '
    .[$profile] as $vm
    | if (($vm.repositories // []) | length) > 0 then $vm.repositories
      else [$vm.users[]?.repositories[]?]
      end
  ' "$config"
}

VMS_USER_REPOSITORIES_JSON() {
  local config="$1" profile="$2" user_name="${3:-}"
  jq -c --arg profile "$profile" --arg user "$user_name" '
    def valor_booleano($objeto; $campo; $predeterminado):
      if ($objeto | has($campo)) then $objeto[$campo] else $predeterminado end;
    .[$profile] as $vm
    | ($vm.repositories // []) as $definitions
    | if ($definitions | length) == 0 then
        [$vm.users[]?
          | select($user == "" or ((.name // "" | ascii_downcase) == ($user | ascii_downcase)))
          | .repositories[]?]
      elif $user == "" then
        [$definitions[]
          | . + {
              can_read:true,
              can_write:true,
              dispatch_enabled:valor_booleano(.; "dispatch_enabled"; true)
            }]
      else
        [$vm.users[]?
          | select($user == "" or ((.name // "" | ascii_downcase) == ($user | ascii_downcase)))
          | .repositories[]? as $grant
          | $definitions[]
          | select(.id == ($grant.id // $grant.repository))
          | . + {
              can_read:valor_booleano($grant; "can_read"; true),
              can_write:valor_booleano($grant; "can_write"; false),
              dispatch_enabled:(valor_booleano(.; "dispatch_enabled"; true) and valor_booleano($grant; "can_read"; true))
            }]
      end
  ' "$config"
}

VMS_FIELD() {
  local config="$1" profile="$2" field="$3"
  jq -er --arg profile "$profile" --arg field "$field" '
    .[$profile] as $vm
    | (($vm.repositories // [$vm.users[0].repositories[0]])[0] // {}) as $repository
    | if $field == "ip" then $vm.ip
      elif $field == "user" then $vm.user // $vm.users[0].name
      elif $field == "workspace" then $repository.path // $repository.workspace // $vm.workspace
      elif ($repository | has($field)) then $repository[$field]
      elif ($vm | has($field)) then $vm[$field]
      else empty
      end
  ' "$config" 2>/dev/null || true
}
