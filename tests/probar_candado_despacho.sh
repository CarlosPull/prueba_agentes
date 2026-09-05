#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools/despacho" "$tmp/proyecto"
cp "$ROOT/tools/despacho/validar_y_despachar.sh" "$tmp/tools/despacho/"
cat > "$tmp/tools/despacho/despachar_vm.sh" <<'SH'
#!/usr/bin/env bash
printf 'ejecutado\n' >> "$2/contador"
sleep 0.2
SH
chmod +x "$tmp/tools/despacho/"*.sh
pids=()
for intento in {1..12}; do
  "$tmp/tools/despacho/validar_y_despachar.sh" backend "$tmp/proyecto" 'Consultar un endpoint PHP' --dispatch-id mismo >"$tmp/$intento.log" 2>&1 &
  pids+=("$!")
done
successes=0
for pid in "${pids[@]}"; do if wait "$pid"; then successes=$((successes+1)); fi; done
[ "$successes" = 1 ] && [ "$(wc -l < "$tmp/proyecto/contador")" = 1 ]
touch "$tmp/proyecto/.ejecucion_lock.antiguo"
if "$tmp/tools/despacho/validar_y_despachar.sh" backend "$tmp/proyecto" 'Consultar PHP' --dispatch-id antiguo >/dev/null 2>&1; then exit 1; fi
echo '✓ Doce despachos concurrentes producen una sola ejecución; se respetan candados antiguos.'
