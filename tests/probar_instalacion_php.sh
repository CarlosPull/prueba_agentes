#!/usr/bin/env bash
# Pruebas aisladas: dobles de APT/sudo/PHP, sin SSH ni instalación real.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/bin"
export REGISTRO="$TEMP/registro" ESTADO_PPA="$TEMP/ppa"
# Sustituir sólo la lectura del SO en una copia; producción usa /etc/os-release.
sed "s|^\. /etc/os-release$|. \"$TEMP/os-release\"|" \
  "$ROOT/tools/remotos/instalar_paquetes_backend.sh" > "$TEMP/instalar.sh"
cat > "$TEMP/bin/sudo" <<'DOBLE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REGISTRO"
if [ "$1" = add-apt-repository ]; then touch "$ESTADO_PPA"; fi
DOBLE
cat > "$TEMP/bin/apt-cache" <<'DOBLE'
#!/usr/bin/env bash
if [ "${FALLO_APT:-0}" = 1 ]; then exit 42; fi
if [ "$1" = depends ]; then
  [ -z "${NATIVA:-}" ] || echo "  Depends: php$NATIVA-cli"
  exit 0
fi
version="${BASE:-}"
[ ! -f "$ESTADO_PPA" ] || version="${PPA:-}"
case "$2" in
  "php${version%.*}-"*)
    if [ "$2" != "${FALTANTE:-}" ]; then echo "  Candidate: $version-0ubuntu1"; exit 0; fi ;;
esac
echo '  Candidate: (none)'
DOBLE
cat > "$TEMP/bin/dpkg" <<'DOBLE'
#!/usr/bin/env bash
# Comparador numérico sólo para las versiones estables de estas fixtures.
awk -v a="$2" -v b="$4" 'BEGIN {
  split(a,x,"."); split(b,y,".");
  for(i=1;i<=3;i++) { if(x[i]+0>y[i]+0)exit 0; if(x[i]+0<y[i]+0)exit 1; }
  exit 0;
}'
DOBLE
cat > "$TEMP/bin/php" <<'DOBLE'
#!/usr/bin/env bash
# La existencia del ejecutable no debe decidir si los paquetes están disponibles.
[ "${PHP_FINAL_FALLA:-0}" != 1 ] || exit 1
printf '8.5.4'
DOBLE
chmod +x "$TEMP/bin/"*
export PATH="$TEMP/bin:$PATH"

caso() {
  local nombre="$1" so="$2" base="$3" nativa="$4" ppa="$5" esperado="$6" seleccion="$7" usa_ppa="$8"
  rm -f "$ESTADO_PPA"
  : > "$REGISTRO"
  printf 'ID=%s\nVERSION_ID=%s\nPRETTY_NAME="Prueba %s"\n' "${so%%:*}" "${so#*:}" "$so" > "$TEMP/os-release"
  local estado=0
  BASE="$base" NATIVA="$nativa" PPA="$ppa" bash "$TEMP/instalar.sh" 8.4 8.4.1 git curl > "$TEMP/salida" 2>&1 || estado=$?
  if { [ "$esperado" = ok ] && [ "$estado" -ne 0 ]; } || { [ "$esperado" = error ] && [ "$estado" -eq 0 ]; }; then
    cat "$TEMP/salida"; echo "FALLO: $nombre (estado $estado)"; exit 1
  fi
  if [ "$esperado" = ok ]; then
    grep -F "install -y php$seleccion-cli php$seleccion-mbstring" "$REGISTRO" >/dev/null
    grep -F "update-alternatives --set php /usr/bin/php$seleccion" "$REGISTRO" >/dev/null
  elif grep -F 'install -y php' "$REGISTRO" >/dev/null && [ "${PHP_FINAL_FALLA:-0}" != 1 ]; then
    echo "FALLO: instalación de PHP sin candidatos en $nombre"; exit 1
  fi
  if [ "$usa_ppa" = si ]; then
    test -f "$ESTADO_PPA"
  else
    test ! -f "$ESTADO_PPA"
  fi
  echo "✓ $nombre"
}
caso '26.04 usa PHP 8.5 nativo sin PPA' ubuntu:26.04 8.5.4 8.5 '' ok 8.5 no
grep -F 'Aviso: PHP 8.4' "$TEMP/salida" >/dev/null
caso 'Versión exacta disponible sin PPA' ubuntu:26.04 8.4.2 8.4 '' ok 8.4 no
caso '24.04 instala versión solicitada desde PPA' ubuntu:24.04 8.3.0 8.3 8.4.2 ok 8.4 si
caso '22.04 instala versión solicitada desde PPA' ubuntu:22.04 '' 8.1 8.4.2 ok 8.4 si
caso 'PPA sin candidatos falla' ubuntu:24.04 '' 8.3 '' error '' si
caso 'SO no compatible sin candidatos falla' ubuntu:26.04 '' '' '' error '' no
caso 'No añade PPA Ubuntu en otra distribución' debian:24.04 '' '' 8.4.2 error '' no
caso 'Rechaza versión nativa inferior al mínimo' ubuntu:26.04 8.4.0 8.4 '' error '' no
caso 'No cambia automáticamente de major' ubuntu:26.04 9.0.1 9.0 '' error '' no
FALTANTE=php8.5-xml caso 'Rechaza extensiones ausentes' ubuntu:26.04 8.5.4 8.5 '' error '' no
FALLO_APT=1 caso 'Errores de APT no instalan PHP' ubuntu:26.04 8.5.4 8.5 '' error '' no
PHP_FINAL_FALLA=1 caso 'Conserva validación final del PHP instalado' ubuntu:26.04 8.5.4 8.5 '' error '' no
echo '✓ Pruebas de instalación PHP completadas.'
