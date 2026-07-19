#!/usr/bin/env bash
# Succeeds on the FIRST call (establishes a session), then fails on every call
# after. So on a later turn the resume call fails AND its stateless retry fails
# too — proving a genuine (non-stale) error is NOT masked by the resume
# fallback: the run aborts loud with the real diagnostic.
set -u
cf="${CALL_COUNT_FILE:?CALL_COUNT_FILE required}"
c=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$c" > "$cf"
if [ "$c" -ge 2 ]; then
  echo "boom: persistent auth failure (call $c)" >&2
  exit 1
fi
prompt="${@: -1}"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
printf '{"type":"result","subtype":"success","session_id":"g-sess-1","is_error":false,"result":%s}\n' \
  "$(printf 'GENFAIL-OK (saw %s chars)' "$n" | jq -Rs .)"
