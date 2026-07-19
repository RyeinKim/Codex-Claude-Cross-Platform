#!/usr/bin/env bash
# Mints a session_id on a fresh (create) call, but on a RESUMED call succeeds
# WITHOUT emitting `.session_id` — a plausible real-CLI shape. Lets a test prove
# the SIDFILE clear in run_turn stops a stale id (e.g. the counterpart's) from
# being mis-persisted when a resumed turn returns no new id.
set -u
resume=""
prev=""
for a in "$@"; do
  [ "$prev" = "--resume" ] && resume="$a"
  prev="$a"
done
prompt="${@: -1}"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
[ -n "${RESUME_LOG:-}" ] && printf 'claude resume=%s chars=%s\n' "${resume:-none}" "$n" >> "$RESUME_LOG"
if [ -n "$resume" ]; then
  # resumed turn: succeed, but deliberately omit session_id
  printf '{"type":"result","subtype":"success","is_error":false,"result":%s}\n' \
    "$(printf 'NOID-CLAUDE resumed (saw %s chars)' "$n" | jq -Rs .)"
else
  printf '{"type":"result","subtype":"success","session_id":"claude-sess-1","is_error":false,"result":%s}\n' \
    "$(printf 'NOID-CLAUDE created (saw %s chars)' "$n" | jq -Rs .)"
fi
