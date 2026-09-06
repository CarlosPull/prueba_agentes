#!/usr/bin/env bash
# Se usa tanto al preparar como antes de cada ejecución.
set -euo pipefail
container="${1:?}"; volume="${2:?}"
[ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] || exit 1
podman inspect "$container" | jq -e --arg volume "$volume" '
  .[0] | .State.Running==true and .HostConfig.Privileged==false and .HostConfig.ReadonlyRootfs==true
  and (.Config.User=="1000:1000" or .Config.User=="1000")
  and (.HostConfig.NetworkMode!="host") and (.HostConfig.PidMode!="host")
  and (.EffectiveCaps|type=="array" and length==0)
  and (.BoundingCaps|type=="array" and length==0)
  and (.HostConfig.SecurityOpt|any(.=="no-new-privileges" or .=="no-new-privileges=true"))
  and ([.Mounts[]? | select(.Destination=="/workspace" and .Name==$volume and .Type=="volume")]|length)==1
  and ([.Mounts[]? | select(.Destination!="/workspace" and (.Destination!="/tmp" or .Type!="tmpfs"))]|length)==0
' >/dev/null || { echo 'El contenedor no cumple el aislamiento obligatorio.' >&2; exit 1; }
podman exec --user 1000:1000 "$container" bwrap --unshare-pid --ro-bind / / --proc /proc --dev /dev /bin/true >/dev/null || {
  echo 'Bubblewrap no puede aplicar su aislamiento en este host.' >&2; exit 4;
}
podman exec "$container" sh -c 'test ! -e /run/podman/podman.sock && test ! -e /var/run/docker.sock'
