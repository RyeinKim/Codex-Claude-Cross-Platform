#!/usr/bin/env bash
# Simulates a STALE/expired session: fails whenever asked to --resume, but
# succeeds on a fresh (no-resume) call. Lets a test prove the bounded single
# stateless retry self-heals an expired session.
set -u
resume=""
prev=""
for a in "$@"; do
  [ "$prev" = "--resume" ] && resume="$a"
  prev="$a"
done
if [ -n "$resume" ]; then
  echo "stale session: $resume not found (expired)" >&2
  exit 1
fi
prompt="${@: -1}"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
printf '{"type":"result","subtype":"success","session_id":"stale-sess-1","is_error":false,"result":%s}\n' \
  "$(printf 'STALE-CLAUDE ok (saw %s chars)' "$n" | jq -Rs .)"
