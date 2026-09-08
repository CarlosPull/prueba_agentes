#!/usr/bin/env bash
# Instalado en la imagen, nunca en el volumen de código que edita el agente.
set -euo pipefail
umask 077
job="${1:?}"; role="${2:?}"; read_only="${3:?}"
[[ "$job" =~ ^[a-f0-9-]{36}$ ]] && [[ "$role" = backend || "$role" = frontend ]] || exit 1
[[ "$read_only" = true || "$read_only" = false ]] || exit 1
task="$(cat)"
base=/workspace/repositorio
runs=/workspace/ejecuciones
mkdir -p "$runs"
run="$runs/$job"
mkdir "$run"
# Referencia administrada en la imagen/configuración del contenedor, no en el prompt.
base_ref="${REPOSITORY_BASE_REF:-origin/main}"
git -C "$base" rev-parse --verify "$base_ref^{commit}" >/dev/null
# Clon local independiente: .git y el índice del repositorio base no se comparten.
git clone --quiet --no-hardlinks --no-checkout -- "$base" "$run/repo"
commit="$(git -C "$base" rev-parse "$base_ref^{commit}")"
git -C "$run/repo" checkout --quiet -b "codex/tarea-$job" "$commit"
export PI_HARNESS_RUNS_DIR="$run/evidencia"
args=(start --role "$role" --workspace "$run/repo" --agent-dir /opt/agente/actual --backend auto --task -)
[ -z "${BUSINESS_MEMORY_FILE:-}" ] || args+=(--business-memory "$BUSINESS_MEMORY_FILE")
[ "$read_only" = false ] || args+=(--read-only)
[ -z "${PI_PROVIDER:-}" ] || args+=(--provider "$PI_PROVIDER")
[ -z "${PI_MODEL:-}" ] || args+=(--model "$PI_MODEL")
printf '%s\n' "$task" | /opt/pi-harness/bin/pi-harness "${args[@]}"
# La publicación Git requiere un permiso y una fase independiente; este MVP no hace push.
printf '\nEjecución completada. Los cambios permanecen en la copia de trabajo de esta tarea.\n'
