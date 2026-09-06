#!/usr/bin/env bash
set -euo pipefail
umask 077
input="$(cat)"
url="$(jq -r .url <<< "$input")"; branch="$(jq -r .branch <<< "$input")"
# Reintentos nunca hacen pull ni borran cambios.
if [ -e /workspace/repositorio ]; then
  [ "$(git -C /workspace/repositorio remote get-url origin)" = "$url" ]
  git -C /workspace/repositorio rev-parse --verify HEAD >/dev/null
  exit 0
fi
mkdir -p /tmp/clone-auth
trap 'rm -rf /tmp/clone-auth' EXIT
jq -jr .gitToken <<< "$input" > /tmp/clone-auth/token
cat > /tmp/clone-auth/askpass <<'ASK'
#!/bin/sh
case "$1" in *Username*) printf 'x-access-token\n';; *) cat /tmp/clone-auth/token;; esac
ASK
chmod 700 /tmp/clone-auth/askpass
export GIT_ASKPASS=/tmp/clone-auth/askpass GIT_TERMINAL_PROMPT=0
git -c credential.helper= clone --no-checkout --single-branch --branch "$branch" -- "$url" /workspace/repositorio
