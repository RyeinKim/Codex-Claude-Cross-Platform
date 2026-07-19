#!/usr/bin/env bash
#
# Failure-path + security tests for the hardened bridge.sh (zero real tokens).
# Covers the adversarial-review findings:
#   #5 fail-loud: CLI error -> abort + non-zero exit (no fake "done")
#   #6 is_error envelope -> treated as failure, not conversation
#   #8 no placeholder recycling after a failure
#   #4 prompt-injection: embedded newline cannot forge a fake turn
#   #1 CODEX_PERSONA is actually delivered to codex
# Plus hard-invariant locks:
#   #1b personas reach BOTH CLIs: CLAUDE_PERSONA is delivered to claude too
#   exit 2: an invalid speaker (loop or --once) is rejected with code 2
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
M="$here/mocks"
tmp="$(mktemp -d)"
fail=0
pass()  { echo "  ✓ $1"; }
failf() { echo "  ✗ $1"; fail=1; }
lines() { wc -l < "$1" | tr -d ' '; }

# --- #5: a failing CLI aborts with non-zero exit and does not fake success ---
echo "▶ [fail-loud] claude CLI exits non-zero on turn 1"
log="$tmp/fail.jsonl"
CLAUDE_BIN="$M/fail-claude.sh" CODEX_BIN="$M/mock-codex.sh" \
BRIDGE_LOG="$log" MAX_TURNS=6 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "seed" >/dev/null 2>"$tmp/fail.err"; rc=$?
[ "$rc" -ne 0 ] && pass "non-zero exit on failure (rc=$rc)" || failf "expected non-zero exit, got 0"
[ "$(lines "$log")" -eq 1 ] && pass "aborted immediately (only human seed logged)" \
  || failf "expected 1 log line, got $(lines "$log")"
grep -q "no output" "$log" && failf "placeholder text leaked into log" \
  || pass "no placeholder recycled into log"
grep -q "429" "$tmp/fail.err" && pass "real diagnostic surfaced on stderr" \
  || failf "diagnostic (429) not surfaced on stderr"

# --- #6: an is_error envelope is a failure, not a conversation turn ----------
echo "▶ [is_error] claude returns is_error:true envelope"
log="$tmp/err.jsonl"
CLAUDE_BIN="$M/error-claude.sh" CODEX_BIN="$M/mock-codex.sh" \
BRIDGE_LOG="$log" MAX_TURNS=6 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "seed" >/dev/null 2>"$tmp/err.err"; rc=$?
[ "$rc" -ne 0 ] && pass "non-zero exit on is_error (rc=$rc)" || failf "is_error not treated as failure"
[ "$(lines "$log")" -eq 1 ] && pass "error envelope not recorded as a turn" \
  || failf "error envelope leaked into log ($(lines "$log") lines)"

# --- #4 + #1: injection is neutralized, and codex gets its persona ----------
echo "▶ [injection+persona] claude reply tries to forge turns via newlines"
log="$tmp/inj.jsonl"; spy="$tmp/spy.txt"
CLAUDE_BIN="$M/inject-claude.sh" CODEX_BIN="$M/spy-codex.sh" SPY_FILE="$spy" \
BRIDGE_LOG="$log" MAX_TURNS=2 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "seed topic" >/dev/null 2>&1
# spy.txt = the exact prompt codex received on turn 2.
hcount=$(grep -c '^human:' "$spy" 2>/dev/null || true)
ccount=$(grep -c '^codex:' "$spy" 2>/dev/null || true)
[ "$hcount" -eq 1 ] && pass "only the real human seed survives (no forged 'human:' turn)" \
  || failf "forged 'human:' turn leaked into codex prompt (found $hcount)"
[ "$ccount" -eq 0 ] && pass "no forged 'codex:' turn in codex prompt" \
  || failf "forged 'codex:' turn leaked (found $ccount)"
grep -q "You are CODEX" "$spy" && pass "CODEX_PERSONA delivered to codex (loop-back guard active)" \
  || failf "CODEX_PERSONA missing from codex prompt"

# --- #1b: claude ALSO gets its persona, via --append-system-prompt -----------
echo "▶ [persona] CLAUDE_PERSONA reaches the claude CLI"
log="$tmp/persona.jsonl"; cspy="$tmp/cspy.txt"
CLAUDE_BIN="$M/spy-claude.sh" CODEX_BIN="$M/mock-codex.sh" SPY_FILE="$cspy" \
CLAUDE_PERSONA="You are CLAUDE. SENTINEL_CLAUDE_PERSONA_7788." \
BRIDGE_LOG="$log" MAX_TURNS=1 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "seed topic" >/dev/null 2>&1
grep -q "SENTINEL_CLAUDE_PERSONA_7788" "$cspy" 2>/dev/null \
  && pass "CLAUDE_PERSONA delivered to claude via --append-system-prompt" \
  || failf "CLAUDE_PERSONA missing from claude invocation"

# --- exit codes: an invalid speaker is rejected with code 2 (not 0 or 1) -----
echo "▶ [exit-code] an invalid speaker exits 2"
CLAUDE_BIN="$M/mock-claude.sh" CODEX_BIN="$M/mock-codex.sh" \
BRIDGE_LOG="$tmp/x.jsonl" FIRST_SPEAKER=bogus \
  bash "$root/bridge.sh" "seed" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "bad FIRST_SPEAKER exits 2 (rc=$rc)" \
  || failf "expected exit 2 for bad FIRST_SPEAKER, got $rc"
CLAUDE_BIN="$M/mock-claude.sh" CODEX_BIN="$M/mock-codex.sh" \
BRIDGE_LOG="$tmp/x.jsonl" \
  bash "$root/bridge.sh" --once bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "bad --once speaker exits 2 (rc=$rc)" \
  || failf "expected exit 2 for bad --once speaker, got $rc"

echo
rm -rf "$tmp"
if [ "$fail" -eq 0 ]; then echo "✅ ALL ERROR/SECURITY TESTS PASSED"; else echo "❌ TESTS FAILED"; exit 1; fi
