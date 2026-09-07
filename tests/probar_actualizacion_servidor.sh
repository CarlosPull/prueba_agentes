#!/usr/bin/env bash
# Comprueba el candado con dobles de Git/Podman; no toca servicios ni repositorios.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flock >/dev/null || { echo 'Esta prueba requiere flock (Linux).'; exit 1; }
tmp="$(mktemp -d)"
cleanup() {
  if [ -f "$tmp/hijo.pid" ]; then kill "$(cat "$tmp/hijo.pid")" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/repo/tools/sincronizacion" "$tmp/bin"
cp "$ROOT/tools/sincronizacion/actualizar_servidor_plataforma.sh" "$tmp/repo/tools/sincronizacion/"
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
  fetch) exit "${FALLAR_FETCH:-0}" ;;
  rev-parse) if [ "$2" = HEAD ]; then echo anterior; else echo nuevo; fi ;;
esac
GIT
cat > "$tmp/bin/podman" <<'PODMAN'
#!/usr/bin/env bash
if [ -e /proc/$$/fd/9 ]; then touch "$PRUEBA_TMP/descriptor-heredado"; fi
if [ "$1" = build ]; then
  sleep 60 </dev/null >/dev/null 2>&1 &
  echo "$!" > "$PRUEBA_TMP/hijo.pid"
fi
PODMAN
chmod +x "$tmp/bin/git" "$tmp/bin/podman"
export PATH="$tmp/bin:$PATH" PRUEBA_TMP="$tmp"
bash "$tmp/repo/tools/sincronizacion/actualizar_servidor_plataforma.sh"
test ! -e "$tmp/descriptor-heredado"
kill -0 "$(cat "$tmp/hijo.pid")"
flock -n "$tmp/repo/.private/auto_update.lock" true
if FALLAR_FETCH=1 bash "$tmp/repo/tools/sincronizacion/actualizar_servidor_plataforma.sh"; then
  echo 'Error: un fallo de Git se informó como éxito.'; exit 1
fi
grep -q 'Error: no se pudo consultar' "$tmp/repo/.private/auto_update_plataforma.log"
flock -n "$tmp/repo/.private/auto_update.lock" true
echo 'Correcto: Podman no hereda el candado y los errores de Git quedan registrados.'
