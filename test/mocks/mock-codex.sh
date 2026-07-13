#!/usr/bin/env bash
# Mock of:  codex exec - --sandbox read-only --skip-git-repo-check -o <file>
# Reads the prompt from stdin, writes its reply to the file after -o (or stdout),
# echoing how many characters of context it received.
set -u
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
prompt="$(cat)"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
reply="MOCK-CODEX reply (saw ${n} chars)"
if [ -n "$out" ]; then
  printf '%s\n' "$reply" > "$out"
else
  printf '%s\n' "$reply"
fi
