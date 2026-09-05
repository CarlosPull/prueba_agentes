#!/usr/bin/env bash
# Introducción local de credenciales, sin argumentos que expongan la contraseña.
set -euo pipefail
[ -t 0 ] || { echo 'Ejecuta este comando desde una terminal interactiva.' >&2; exit 1; }
read -r -p 'Correo del administrador inicial: ' email
read -r -s -p 'Contraseña (mínimo 12 caracteres): ' password
printf '\n'
read -r -s -p 'Repite la contraseña: ' confirmation
printf '\n'
[ "$password" = "$confirmation" ] || { echo 'Las contraseñas no coinciden.' >&2; exit 1; }
printf '%s\n' "$password" | podman exec -i --env "ADMIN_EMAIL=$email" orquestador-api node dist/cli.js admin
unset password confirmation
