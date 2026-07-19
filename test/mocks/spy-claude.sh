#!/usr/bin/env bash
# Captures the --append-system-prompt value (the CLAUDE persona) it received to
# $SPY_FILE, then replies with a valid `claude -p --output-format json` envelope.
# Lets a test prove CLAUDE_PERSONA actually reaches the claude CLI — the mirror
# of spy-codex.sh, so the "personas must reach BOTH CLIs" invariant is locked.
set -u
persona=""
prev=""
for a in "$@"; do
  [ "$prev" = "--append-system-prompt" ] && persona="$a"
  prev="$a"
done
[ -n "${SPY_FILE:-}" ] && printf '%s' "$persona" > "$SPY_FILE"
result="SPY-CLAUDE ok"
printf '{"type":"result","subtype":"success","session_id":"spy-claude-session","is_error":false,"result":%s}\n' \
  "$(printf '%s' "$result" | jq -Rs .)"
