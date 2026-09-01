#!/usr/bin/env bash
# Emite únicamente la respuesta final del asistente desde el JSONL bruto de Pi.
set -euo pipefail

EVENTS_FILE="${1:-}"
[ -s "$EVENTS_FILE" ] || exit 0

jq -r '
  select(.type == "message_end" and .message.role == "assistant")
  | [.message.content[]? | select(.type == "text") | .text]
  | join("\n")
' "$EVENTS_FILE"
