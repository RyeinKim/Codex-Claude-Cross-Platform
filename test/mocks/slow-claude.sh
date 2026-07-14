#!/usr/bin/env bash
# Like mock-claude.sh but sleeps first, so a test can cancel it mid-turn.
set -u
sleep "${SLOW_SECS:-2}"
prompt="${@: -1}"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
printf '{"type":"result","subtype":"success","session_id":"slow","is_error":false,"result":%s}\n' \
  "$(printf 'SLOW-CLAUDE reply (saw %s chars)' "$n" | jq -Rs .)"
