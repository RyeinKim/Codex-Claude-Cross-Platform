#!/usr/bin/env bash
# Mock of:  claude -p --output-format json --append-system-prompt <persona> "<prompt>"
# Emits a single JSON envelope shaped like the real `claude -p --output-format json`,
# echoing how many characters of context it received (used to prove context grows).
set -u
prompt="${@: -1}"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
result="MOCK-CLAUDE reply (saw ${n} chars)"
printf '{"type":"result","subtype":"success","session_id":"mock-claude-session","is_error":false,"result":%s}\n' \
  "$(printf '%s' "$result" | jq -Rs .)"
