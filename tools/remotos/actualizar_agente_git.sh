#!/usr/bin/env bash
# Se ejecuta dentro de cada VM: descarga su rama Git y activa una versión validada.
set -euo pipefail

[ "${AGENTE_DEBUG:-0}" = "1" ] && set -x

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$BASE/git-agent.conf"
REPO="$BASE/repositorio.git"
VERSIONES="$BASE/.versiones"
LOCK="$BASE/.actualizacion.lock"

LOG() {
  if [ "${AGENTE_SILENCIOSO:-0}" != "1" ]; then
    echo "$*"
  fi
}

if [ ! -s "$CONFIG" ]; then
  echo "Error: no existe la configuración Git '$CONFIG'." >&2
  exit 1
fi

GIT_URL="$(sed -n '1p' "$CONFIG")"
GIT_BRANCH="$(sed -n '2p' "$CONFIG")"
ROLE="$(sed -n '3p' "$CONFIG")"
AGENT_PATH="$(sed -n '4p' "$CONFIG")"

if [ -z "$GIT_URL" ] || [ -z "$GIT_BRANCH" ] || [ -z "$ROLE" ] || [ -z "$AGENT_PATH" ]; then
  echo "Error: configuración Git incompleta en '$CONFIG'." >&2
  exit 1
fi

if [[ ! "$GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ ! "$ROLE" =~ ^[a-z0-9-]+$ ]] || [[ ! "$AGENT_PATH" =~ ^skills/[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: rama, rol o ruta del agente no válidos en '$CONFIG'." >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "Error: git no está instalado en la VM." >&2
  exit 1
}
command -v flock >/dev/null 2>&1 || {
  echo "Error: flock no está instalado en la VM." >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  echo "Error: tar no está instalado en la VM." >&2
  exit 1
}

mkdir -p "$BASE" "$VERSIONES"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
exec 9>"$LOCK"
flock -x 9


if [ ! -d "$REPO" ]; then
  repo_tmp="$BASE/.repositorio.git.tmp.$$"
  trap 'rm -rf "${repo_tmp:-}" "${version_tmp:-}"' EXIT
  rm -rf "$repo_tmp"
  if ! git clone --bare --filter=blob:none --single-branch --branch "$GIT_BRANCH" "$GIT_URL" "$repo_tmp" 2>/dev/null; then
    if [[ "$GIT_URL" =~ ^https://github\.com/([^/]+)/([^/]+)(\.git)?$ ]]; then
      ssh_git_url="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}.git"
      git clone --bare --filter=blob:none --single-branch --branch "$GIT_BRANCH" "$ssh_git_url" "$repo_tmp"
    else
      exit 1
    fi
  fi
  mv "$repo_tmp" "$REPO"
fi


git --git-dir="$REPO" fetch --quiet --prune origin \
  "+refs/heads/$GIT_BRANCH:refs/remotes/origin/$GIT_BRANCH"

commit="$(git --git-dir="$REPO" rev-parse "refs/remotes/origin/$GIT_BRANCH^{commit}")"
version="$(git --git-dir="$REPO" rev-parse "$commit:$AGENT_PATH")"
version_dir="$VERSIONES/$version"
version_tmp="$VERSIONES/.${version}.tmp.$$"

version_actual=""
if [ -s "$BASE/actual/.agent-version" ]; then
  version_actual="$(cat "$BASE/actual/.agent-version")"
fi

if [ "$version_actual" = "$version" ]; then
  printf '%s\n' "$commit" > "$BASE/actual/.git-commit"
  LOG "✓ Agente '$ROLE' ya está actualizado desde Git ($version, commit $commit)."
  exit 0
fi

trap 'rm -rf "${repo_tmp:-}" "${version_tmp:-}"' EXIT
rm -rf "$version_tmp"
mkdir -p "$version_tmp"

git --git-dir="$REPO" archive "$commit:$AGENT_PATH" | tar -x -C "$version_tmp"

test -s "$version_tmp/SKILL.md"
test "$(sed -n '1p' "$version_tmp/SKILL.md")" = "---"
printf '%s\n' "$version" > "$version_tmp/.agent-version"
printf '%s\n' "$commit" > "$version_tmp/.git-commit"

if [ ! -d "$version_dir" ]; then
  mv "$version_tmp" "$version_dir"
else
  rm -rf "$version_tmp"
fi

ln -sfn ".versiones/$version" "$BASE/actual.nuevo"
mv -Tf "$BASE/actual.nuevo" "$BASE/actual"
test "$(cat "$BASE/actual/.agent-version")" = "$version"

trap - EXIT
echo "✓ Agente '$ROLE' descargado desde Git y activado ($version, commit $commit)."
