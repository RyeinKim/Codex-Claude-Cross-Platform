#!/usr/bin/env bash
# Captures the exact prompt it received (stdin) to $SPY_FILE, then replies
# normally. Lets a test inspect what codex actually saw.
set -u
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
prompt="$(cat)"
[ -n "${SPY_FILE:-}" ] && printf '%s' "$prompt" > "$SPY_FILE"
reply="SPY-CODEX ok"
if [ -n "$out" ]; then printf '%s\n' "$reply" > "$out"; else printf '%s\n' "$reply"; fi
