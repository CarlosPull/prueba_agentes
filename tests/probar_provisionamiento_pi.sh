#!/usr/bin/env bash
# Verifica localmente la estructura del provisionador de Pi sin abrir conexiones SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$ROOT/tools/provisionar_vm_pi.sh"
REMOTE="$ROOT/tools/remotos/provisionar_vm_pi.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prueba-config-pi.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

bash -n "$LOCAL" "$REMOTE" "$ROOT/pi-harness/bin/pi-harness"

grep -F '@earendil-works/pi-coding-agent@' "$REMOTE" >/dev/null
grep -F 'npm install -g --ignore-scripts' "$REMOTE" >/dev/null
grep -F 'bwrap --ro-bind / /' "$REMOTE" >/dev/null
grep -F 'apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict' "$LOCAL" >/dev/null
grep -F 'apparmor_parser -R /etc/apparmor.d/prueba-agentes-bwrap' "$LOCAL" >/dev/null
grep -F 'apparmor_parser -r /etc/apparmor.d/prueba-agentes-bwrap' "$LOCAL" >/dev/null
grep -F 'profile prueba-agentes-bwrap /usr/bin/bwrap flags=(unconfined)' "$ROOT/tools/remotos/prueba-agentes-bwrap.apparmor" >/dev/null
grep -F 'userns,' "$ROOT/tools/remotos/prueba-agentes-bwrap.apparmor" >/dev/null
grep -F 'instalar_actualizacion_git.sh' "$LOCAL" >/dev/null
grep -F 'configurar_ssh_vm.sh' "$LOCAL" >/dev/null
grep -F 'pi-harness' "$LOCAL" >/dev/null
grep -F "rsync -az --delete --exclude='.git/'" "$LOCAL" >/dev/null

if grep -Eq 'python3 -m pip|RUNNER_REPO|agent_runner_local_path|opencode-ai@' "$LOCAL" "$REMOTE"; then
  echo "FALLO: el provisionador Pi todavía contiene una instalación de agent-runner/OpenCode." >&2
  exit 1
fi

if "$LOCAL" 'Perfil Invalido' >/dev/null 2>&1; then
  echo "FALLO: se aceptó un perfil con formato inseguro." >&2
  exit 1
fi

cp "$ROOT/config/vms.json" "$TEMP_DIR/vms.json"
branch_actual="$(git -C "$ROOT" branch --show-current)"
printf '%s\n' \
  '192.168.50.231' 'carlos2' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' \
  | PRUEBA_AGENTES_VMS_CONF="$TEMP_DIR/vms.json" "$LOCAL" backend-pi-automatico --solo-configurar >/dev/null

jq -e --arg branch "$branch_actual" '
  .["backend-pi-automatico"] |
  .ip == "192.168.50.231" and
  .user == "carlos2" and
  .workspace == "/home/carlos2/laravel-dev" and
  (.repositories | length) == 1 and
  .repositories[0].path == "/home/carlos2/laravel-dev" and
  .repositories[0].kind == "module" and
  (.repositories[0].business_memory | endswith(".md")) and
  .stack == "backend" and
  .source_mode == "local" and
  .agent_update_mode == "git" and
  .git_branch == $branch and
  .pi_version == "latest"
' "$TEMP_DIR/vms.json" >/dev/null

jq -e 'has("backend-pi-automatico") | not' "$ROOT/config/vms.json" >/dev/null

echo "OK: configuración automática, Pi y perfil AppArmor de Bubblewrap verificados sin usar SSH."
