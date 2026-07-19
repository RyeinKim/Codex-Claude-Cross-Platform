#!/usr/bin/env bash
#
# Opt-in resume (BRIDGE_RESUME=1) tests for bridge.sh LOOP mode — zero real tokens.
# Locks the priority-5 optimization's invariants:
#   - session id captured on turn 1, threaded via --resume on later turns
#   - a resumed turn sends a DELTA, far smaller than the full transcript
#   - a fresh run resets sessions (truncation clears the handles)
#   - codex resume uses `exec resume`, read-only via -c, --json, no --ephemeral
#   - persona reaches BOTH CLIs on every turn (claude flag; codex stdin prepend)
#   - fail-loud: a stale session self-heals in one stateless retry, but a genuine
#     error survives the retry and aborts the run (never masked)
#   - the injection guard still collapses newlines in the delta
# All mocks (CLAUDE_BIN/CODEX_BIN); never touches the real CLIs.
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
M="$here/mocks"
tmp="$(mktemp -d)"
fail=0
pass()  { echo "  ✓ $1"; }
failf() { echo "  ✗ $1"; fail=1; }
chars_of() { printf '%s' "$1" | sed 's/.*chars=\([0-9]*\).*/\1/'; }

# ── resume ON: a 6-turn loop (claude opens; claude speaks turns 1,3,5) ─────────
echo "▶ [resume] BRIDGE_RESUME=1 threads sessions and sends deltas"
logB="$tmp/on.jsonl"; rB="$tmp/on.resume"; cprompt="$tmp/codex_prompt.txt"; : > "$rB"
CLAUDE_BIN="$M/resume-claude.sh" CODEX_BIN="$M/resume-codex.sh" \
RESUME_LOG="$rB" CODEX_PROMPT_FILE="$cprompt" \
BRIDGE_RESUME=1 BRIDGE_LOG="$logB" MAX_TURNS=6 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "TEST TOPIC: resume please" >/dev/null 2>"$tmp/on.err"; rc=$?

[ "$rc" -eq 0 ] && pass "resume loop completed (rc=0)" \
  || failf "resume loop failed rc=$rc: $(head -c 300 "$tmp/on.err")"

roles=$(jq -r '.role' "$logB" | paste -sd, -)
[ "$roles" = "human,claude,codex,claude,codex,claude,codex" ] \
  && pass "roles still strictly alternate under resume" \
  || failf "roles wrong: $roles"

c1=$(grep '^claude ' "$rB" | sed -n 1p)
c2=$(grep '^claude ' "$rB" | sed -n 2p)
echo "$c1" | grep -q 'resume=none'          && pass "claude turn 1 creates a session (no --resume)" || failf "claude t1 should not resume: $c1"
echo "$c2" | grep -q 'resume=claude-sess-1' && pass "claude turn 2 threads the captured session id" || failf "claude t2 should --resume claude-sess-1: $c2"
[ "$(grep -c 'persona=yes' "$rB")" -eq "$(grep -c '^claude ' "$rB")" ] \
  && pass "CLAUDE_PERSONA delivered on EVERY turn (incl. resume turns)" \
  || failf "persona missing on some claude turn: $(grep '^claude ' "$rB")"

x1=$(grep '^codex ' "$rB" | sed -n 1p)
x2=$(grep '^codex ' "$rB" | sed -n 2p)
echo "$x1" | grep -q 'mode=create' && echo "$x1" | grep -q 'json=1' \
  && pass "codex turn 1 creates a session under --json (id captured)" || failf "codex t1 wrong: $x1"
echo "$x2" | grep -q 'mode=resume'                  && pass "codex turn 2 uses exec resume" || failf "codex t2 not resume: $x2"
echo "$x2" | grep -q 'sandbox=sandbox_mode=read-only' && pass "codex resume enforces read-only via -c" || failf "codex resume missing -c sandbox_mode=read-only: $x2"
echo "$x2" | grep -q 'ephemeral=0'                  && pass "codex resume never uses --ephemeral" || failf "codex resume wrongly ephemeral: $x2"
echo "$x2" | grep -q 'skipgit=1'                    && pass "codex resume keeps --skip-git-repo-check" || failf "codex resume dropped --skip-git-repo-check: $x2"
grep -q "You are CODEX" "$cprompt" \
  && pass "CODEX_PERSONA re-prepended on codex resume turns" \
  || failf "codex persona missing from resumed prompt"
grep -q "claude: MOCK-CLAUDE reply" "$cprompt" \
  && pass "the delta actually carries the counterpart's latest message" \
  || failf "delta is empty — counterpart's message not delivered"

# ── full-vs-delta head-to-head: same scenario, resume OFF, compare turn-5 size ─
echo "▶ [resume] a resumed turn sends far fewer chars than the full transcript"
logA="$tmp/off.jsonl"; rA="$tmp/off.resume"; : > "$rA"
CLAUDE_BIN="$M/resume-claude.sh" CODEX_BIN="$M/resume-codex.sh" RESUME_LOG="$rA" \
BRIDGE_LOG="$logA" MAX_TURNS=6 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "TEST TOPIC: resume please" >/dev/null 2>&1
a3=$(chars_of "$(grep '^claude ' "$rA" | sed -n 3p)")   # full transcript at turn 5
b3=$(chars_of "$(grep '^claude ' "$rB" | sed -n 3p)")   # delta at turn 5
if [ -n "$a3" ] && [ -n "$b3" ] && [ "$b3" -lt "$a3" ]; then
  pass "resume turn 5 is a delta (${b3} chars) vs full transcript (${a3} chars)"
else failf "delta not smaller than full (resume=$b3 full=$a3)"; fi

# ── a fresh run resets the sessions (truncation clears the handles) ────────────
echo "▶ [resume] a fresh run starts from a clean session"
r2="$tmp/reset.resume"; : > "$r2"
CLAUDE_BIN="$M/resume-claude.sh" CODEX_BIN="$M/resume-codex.sh" RESUME_LOG="$r2" \
BRIDGE_RESUME=1 BRIDGE_LOG="$tmp/reset.jsonl" MAX_TURNS=2 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "second topic" >/dev/null 2>&1
grep '^claude ' "$r2" | sed -n 1p | grep -q 'resume=none' \
  && pass "fresh run's first turn creates again (session reset by truncation)" \
  || failf "fresh run did not reset the session"

# ── fail-loud #1: a stale session self-heals in exactly one stateless retry ────
echo "▶ [resume] a stale session self-heals with one stateless retry"
logS="$tmp/stale.jsonl"
CLAUDE_BIN="$M/stale-claude.sh" CODEX_BIN="$M/resume-codex.sh" \
BRIDGE_RESUME=1 BRIDGE_LOG="$logS" MAX_TURNS=4 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "stale topic" >/dev/null 2>"$tmp/stale.err"; rc=$?
[ "$rc" -eq 0 ] && pass "run recovered from the stale session (rc=0)" || failf "stale run failed rc=$rc"
[ "$(jq -r '.role' "$logS" | wc -l | tr -d ' ')" -eq 5 ] \
  && pass "all turns present after self-heal (5 log lines)" || failf "expected 5 lines, got $(jq -r '.role' "$logS" | wc -l | tr -d ' ')"
grep -q "retrying once without resume" "$tmp/stale.err" \
  && pass "the single stateless retry fired (diagnostic on stderr)" || failf "no retry diagnostic on stderr"

# ── fail-loud #2: a genuine error is NOT masked by the resume fallback ─────────
echo "▶ [resume] a genuine error survives the retry and aborts loud"
logG="$tmp/gen.jsonl"; cc="$tmp/calls.txt"; : > "$cc"
CLAUDE_BIN="$M/genfail-claude.sh" CODEX_BIN="$M/resume-codex.sh" CALL_COUNT_FILE="$cc" \
BRIDGE_RESUME=1 BRIDGE_LOG="$logG" MAX_TURNS=4 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "gen topic" >/dev/null 2>"$tmp/gen.err"; rc=$?
[ "$rc" -ne 0 ] && pass "run aborts non-zero on a persistent error (rc=$rc)" || failf "expected non-zero exit, got 0"
grep -q "retrying once without resume" "$tmp/gen.err" && pass "resume failure triggered exactly one retry" || failf "retry did not fire"
grep -q "boom: persistent auth failure" "$tmp/gen.err" \
  && pass "the real diagnostic is surfaced, not masked" || failf "genuine error was swallowed"
[ "$(jq -r '.role' "$logG" | wc -l | tr -d ' ')" -eq 3 ] \
  && pass "the failed turn is not written (3 lines: seed + 2 good turns)" \
  || failf "unexpected line count: $(jq -r '.role' "$logG" | wc -l | tr -d ' ')"

# ── injection guard still applies to the delta ────────────────────────────────
echo "▶ [resume] the injection guard collapses newlines in the delta"
logI="$tmp/inj.jsonl"; iprompt="$tmp/inj_codex_prompt.txt"
CLAUDE_BIN="$M/resume-claude.sh" CODEX_BIN="$M/resume-codex.sh" \
CODEX_PROMPT_FILE="$iprompt" INJECT=1 \
BRIDGE_RESUME=1 BRIDGE_LOG="$logI" MAX_TURNS=4 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "inj topic" >/dev/null 2>&1
hc=$(grep -c '^human:' "$iprompt" 2>/dev/null || true)
cc2=$(grep -c '^codex:' "$iprompt" 2>/dev/null || true)
[ "$hc" -eq 0 ] && pass "no forged 'human:' line in the codex delta (newlines collapsed)" || failf "forged human: line leaked ($hc)"
[ "$cc2" -eq 0 ] && pass "no forged 'codex:' line in the codex delta" || failf "forged codex: line leaked ($cc2)"
grep -q "FORGED HUMAN" "$iprompt" \
  && pass "the forged text still flowed through — but inline, not as a turn" \
  || failf "delta unexpectedly dropped the reply content"

# ── no cross-speaker id leak when a resumed turn returns no new id ─────────────
echo "▶ [resume] a resumed turn with no new id never inherits the other's session"
rN="$tmp/noid.resume"; : > "$rN"
CLAUDE_BIN="$M/noid-claude.sh" CODEX_BIN="$M/resume-codex.sh" RESUME_LOG="$rN" \
BRIDGE_RESUME=1 BRIDGE_LOG="$tmp/noid.jsonl" MAX_TURNS=6 TURN_SLEEP=0 FIRST_SPEAKER=claude \
  bash "$root/bridge.sh" "noid topic" >/dev/null 2>&1
if grep '^claude ' "$rN" | grep -q 'resume=codex'; then
  failf "claude resumed a CODEX thread id — cross-speaker session leak"
else
  pass "claude never resumes a codex thread id (the SIDFILE clear holds)"
fi
grep '^claude ' "$rN" | sed -n 2p | grep -q 'resume=claude-sess-1' \
  && pass "claude keeps its own session even when a resume returns no id" \
  || failf "claude lost its own session id: $(grep '^claude ' "$rN" | sed -n 2p)"

# ── --once stays stateless even with BRIDGE_RESUME=1 in the environment ────────
echo "▶ [resume] --once ignores BRIDGE_RESUME (it is loop-mode-only)"
onlog="$tmp/once.jsonl"; onrl="$tmp/once.resume"; : > "$onrl"
printf '%s\n' '{"ts":"t","role":"human","text":"hi there"}' > "$onlog"
BRIDGE_RESUME=1 CLAUDE_BIN="$M/resume-claude.sh" CODEX_BIN="$M/resume-codex.sh" RESUME_LOG="$onrl" \
BRIDGE_LOG="$onlog" bash "$root/bridge.sh" --once codex >/dev/null 2>&1
grep '^codex ' "$onrl" | sed -n 1p | grep -q 'json=0' \
  && pass "--once codex uses the default (non-resume) path despite BRIDGE_RESUME=1" \
  || failf "--once exercised the resume path: $(grep '^codex ' "$onrl" | sed -n 1p)"
[ "$(wc -l < "$onlog" | tr -d ' ')" -eq 1 ] \
  && pass "--once still appends nothing (sole-writer invariant intact)" \
  || failf "--once wrongly appended to the log"

echo
rm -rf "$tmp"
if [ "$fail" -eq 0 ]; then echo "✅ ALL RESUME TESTS PASSED"; else echo "❌ RESUME TESTS FAILED"; exit 1; fi
