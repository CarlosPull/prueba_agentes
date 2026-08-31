#!/usr/bin/env bash
# Crea, sin sobrescribir, una memoria privada por repositorio dentro de la VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS_CONF="${PRUEBA_AGENTES_VMS_CONF:-$([ -f "$ROOT/config/vms.json" ] && echo "$ROOT/config/vms.json" || echo "$ROOT/vms.json")}"
PROFILE="${1:-}"
[ -n "$PROFILE" ] || { echo "Uso: ./tools/inicializar_memorias_negocio_vm.sh <perfil>" >&2; exit 1; }
ip="$(jq -er --arg profile "$PROFILE" '.[$profile].ip' "$VMS_CONF")"
user="$(jq -er --arg profile "$PROFILE" '.[$profile].user' "$VMS_CONF")"
count="$(jq -r --arg profile "$PROFILE" '(.[$profile].repositories // []) | length' "$VMS_CONF")"
[ "$count" -gt 0 ] || { echo "Error: '$PROFILE' no declara repositorios." >&2; exit 1; }

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
[ ! -f "$HOME/.ssh/id_ed25519" ] || SSH_OPTS+=(-i "$HOME/.ssh/id_ed25519")
while IFS=$'\t' read -r repository module memory_path; do
  [[ "$repository" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "$module" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Error: repositorio/módulo inválido." >&2; exit 1; }
  [[ "$memory_path" =~ ^/home/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.md$ ]] || { echo "Error: ruta de memoria inválida: $memory_path" >&2; exit 1; }
  parent="${memory_path%/*}"
  ssh "${SSH_OPTS[@]}" "$user@$ip" \
    "install -d -m 0700 '$parent'; if [ ! -e '$memory_path' ]; then printf '# Memoria de negocio: %s (%s)\n\nDescribe aquí únicamente las reglas privadas de este módulo.\n' '$module' '$repository' > '$memory_path'; fi; chmod 0600 '$memory_path'"
  echo "✓ Memoria privada preservada: $PROFILE/$repository → $memory_path"
done < <(jq -r --arg profile "$PROFILE" '.[$profile].repositories[] | [.id,.module,.business_memory] | @tsv' "$VMS_CONF")
