#!/usr/bin/env bash
# Captura local; los secretos nunca pasan por el chat, argumentos o navegador.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
profile="${1:?Uso: configurar_credenciales.sh <perfil> <uuid-vm>}"
vm="${2:?Indica el UUID de la VM registrado en la plataforma}"
[[ "$profile" =~ ^[a-z][a-z0-9_-]{0,63}$ && "$vm" =~ ^[a-f0-9-]{36}$ ]] || exit 1
read -r -p 'Proveedor Pi (anthropic/openai): ' provider
[[ "$provider" = anthropic || "$provider" = openai ]] || exit 1
read -r -p 'Modelo: ' model
[[ "$model" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,159}$ ]] || exit 1
read -r -s -p 'API key de Pi: ' api_key; echo
[ -n "$api_key" ] || exit 1
read -r -s -p 'Token Git de solo lectura (Enter para repositorio público): ' git_token; echo
folder="$ROOT/.private/plataforma/provision/profiles"
mkdir -p "$folder"
temp="$(mktemp "$folder/.perfil.XXXXXX")"
trap 'rm -f "$temp"' EXIT
printf '%s\n' "$provider" "$model" "$api_key" "$git_token" "$vm" | podman run --rm -i --network none localhost/orquestador-plataforma:0.1 node -e '
let raw="";process.stdin.setEncoding("utf8");process.stdin.on("data",b=>raw+=b);process.stdin.on("end",()=>{const [provider,model,apiKey,gitToken,vm]=raw.split("\n");process.stdout.write(JSON.stringify({provider,model,apiKey,gitToken,allowedVmIds:[vm]}));});' > "$temp"
unset api_key git_token
mv "$temp" "$folder/$profile.json"
echo 'Perfil guardado para esta VM. Ejecuta plataforma/bin/servicios_trabajadores.sh para cargarlo en los servicios. Los secretos de módulos ya creados no se rotan automáticamente.'
