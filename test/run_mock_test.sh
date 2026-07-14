#!/usr/bin/env bash
#
# Deterministic loop test — runs the REAL bridge.sh against MOCK CLIs.
# Burns zero tokens; proves turn-taking, role tagging, JSONL output,
# and that conversation context accumulates across turns.
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
tmp="$(mktemp -d)"
log="$tmp/conversation.jsonl"
fail=0

pass()  { echo "  ✓ $1"; }
failf() { echo "  ✗ $1"; fail=1; }

echo "▶ running bridge.sh with mock CLIs (MAX_TURNS=4)…"
CLAUDE_BIN="$here/mocks/mock-claude.sh" \
CODEX_BIN="$here/mocks/mock-codex.sh" \
BRIDGE_LOG="$log" MAX_TURNS=4 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "TEST TOPIC: say hello" >/dev/null

echo "▶ assertions:"

lines=$(wc -l < "$log" | tr -d ' ')
[ "$lines" -eq 5 ] && pass "5 log lines (1 human seed + 4 AI turns)" \
                   || failf "expected 5 lines, got $lines"

roles=$(jq -r '.role' "$log" | paste -sd, -)
[ "$roles" = "human,claude,codex,claude,codex" ] \
  && pass "roles strictly alternate: $roles" \
  || failf "role order wrong: $roles"

# count-based (robust against jq -e's empty-last-input exit-status quirk)
count() { jq -r "$1" "$log" | wc -l | tr -d ' '; }

[ "$(count 'select(.role=="claude" and (.text|test("MOCK-CLAUDE")))|.role')" -ge 1 ] \
  && pass "claude turns carry claude output" \
  || failf "claude output marker missing"

[ "$(count 'select(.role=="codex" and (.text|test("MOCK-CODEX")))|.role')" -ge 1 ] \
  && pass "codex turns carry codex output" \
  || failf "codex output marker missing"

[ "$(count 'select(.text=="")|.role')" -eq 0 ] \
  && pass "no empty replies" \
  || failf "found an empty reply"

# Context must grow: codex's 2nd turn sees more chars than its 1st.
c1=$(jq -r 'select(.role=="codex")|.text|capture("saw (?<n>[0-9]+) chars").n' "$log" | sed -n 1p)
c2=$(jq -r 'select(.role=="codex")|.text|capture("saw (?<n>[0-9]+) chars").n' "$log" | sed -n 2p)
if [ -n "$c1" ] && [ -n "$c2" ] && [ "$c2" -gt "$c1" ]; then
  pass "context accumulates across turns (${c1} → ${c2} chars fed to codex)"
else failf "context did not grow (c1=$c1 c2=$c2)"; fi

# --- --once single-turn mode (used by the interactive server) ---
onlog="$tmp/once.jsonl"
printf '%s\n' '{"ts":"t","role":"human","text":"hello there codex and claude"}' > "$onlog"
once_out=$(CLAUDE_BIN="$here/mocks/mock-claude.sh" CODEX_BIN="$here/mocks/mock-codex.sh" \
  BRIDGE_LOG="$onlog" bash "$root/bridge.sh" --once claude)
echo "$once_out" | grep -q "MOCK-CLAUDE" \
  && pass "--once claude prints a single reply to stdout" \
  || failf "--once claude produced no reply"
[ "$(wc -l < "$onlog" | tr -d ' ')" -eq 1 ] \
  && pass "--once does not append to the log (server is the sole writer)" \
  || failf "--once wrongly appended to the log"

echo
rm -rf "$tmp"
if [ "$fail" -eq 0 ]; then
  echo "✅ ALL MOCK TESTS PASSED"
else
  echo "❌ MOCK TESTS FAILED"; exit 1
fi
