#!/usr/bin/env bash
#
# Manual verification harness for BRIDGE_RESUME (priority-5 / task_001 step 15).
#
# NOT an automated test. It deliberately calls the REAL claude/codex CLIs and
# BURNS REAL SUBSCRIPTION QUOTA. It mirrors bridge.sh's exact resume invocations
# to check the two things the mock suite CANNOT:
#   (1) the CLI CONTRACTS the adapter assumes actually hold —
#       - claude: `-p --output-format json --append-system-prompt <p> --resume <id> <prompt>` coexist
#       - codex : `exec resume <thread-id> - --json ... -c sandbox_mode=read-only` works; thread.started present
#   (2) whether resume yields a real prompt-cache DISCOUNT (envelope usage
#       fields), not merely a smaller prompt.
#
# Run modes (one is REQUIRED — it refuses to run bare so it can't burn quota by accident):
#   RUN_REAL_CLI=1 tools/verify_resume_real.sh    # REAL claude/codex — uses quota
#   DRY_RUN=1      tools/verify_resume_real.sh     # plumbing smoke test w/ repo mocks (zero tokens)
# Optional: CLAUDE_BIN=... CODEX_BIN=... to point at specific binaries.
#
# Never wired into test/run_all.sh; never run automatically.
#
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"

DRY_RUN="${DRY_RUN:-0}"
RUN_REAL_CLI="${RUN_REAL_CLI:-0}"
if [ "$DRY_RUN" != "1" ] && [ "$RUN_REAL_CLI" != "1" ]; then
  cat >&2 <<'EOF'
verify_resume_real.sh — manual BRIDGE_RESUME verification (NOT an automated test)

This calls the REAL claude/codex CLIs and BURNS REAL SUBSCRIPTION QUOTA.
Re-run with an explicit mode:

  RUN_REAL_CLI=1 tools/verify_resume_real.sh   # real CLIs (uses quota)
  DRY_RUN=1      tools/verify_resume_real.sh   # plumbing smoke test (repo mocks, zero tokens)

Optional: CLAUDE_BIN=... CODEX_BIN=... to point at specific binaries.
EOF
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ "$DRY_RUN" = "1" ]; then
  CLAUDE_BIN="${CLAUDE_BIN:-$root/test/mocks/resume-claude.sh}"
  CODEX_BIN="${CODEX_BIN:-$root/test/mocks/resume-codex.sh}"
  echo "▶ MODE: DRY_RUN — mocks, zero tokens, plumbing only (usage fields will be n/a)"
else
  CLAUDE_BIN="${CLAUDE_BIN:-claude}"
  CODEX_BIN="${CODEX_BIN:-codex}"
  echo "▶ MODE: RUN_REAL_CLI — real CLIs, using subscription quota"
fi

CP="You are CLAUDE, talking to another AI named CODEX. Reply with ONE short sentence."
XP="You are CODEX, talking to another AI named CLAUDE. Reply with ONE short sentence."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; nodiscount=0
ok()   { echo "  ✓ $1"; }
no()   { echo "  ✗ $1"; fail=1; }
note() { echo "  • $1"; }

# ── claude: create, then resume ───────────────────────────────────────────────
echo; echo "== claude =="
raw1="$("$CLAUDE_BIN" -p --output-format json --append-system-prompt "$CP" \
        "Say hello to CODEX in one sentence." < /dev/null 2>"$tmp/c1.err")"; rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$raw1" | jq -e . >/dev/null 2>&1; then
  no "claude create turn failed (rc=$rc): $(head -c 200 "$tmp/c1.err")"
else
  sid="$(printf '%s' "$raw1" | jq -r '.session_id // empty')"
  [ -n "$sid" ] && ok "create returned .session_id ($sid)" || no "create envelope has no .session_id"
  note "create usage: $(printf '%s' "$raw1" | jq -c '.usage // "n/a"')"
  if [ -n "$sid" ]; then
    raw2="$("$CLAUDE_BIN" -p --output-format json --append-system-prompt "$CP" \
            --resume "$sid" "Reply to CODEX in one sentence." < /dev/null 2>"$tmp/c2.err")"; rc2=$?
    if [ "$rc2" -ne 0 ] || ! printf '%s' "$raw2" | jq -e . >/dev/null 2>&1; then
      no "claude --resume + --output-format json REJECTED (rc=$rc2): $(head -c 200 "$tmp/c2.err")"
      note "→ adapter would self-heal to a stateless full-transcript turn every time (still correct, no saving)"
    else
      [ "$(printf '%s' "$raw2" | jq -r '.is_error // false')" = "true" ] \
        && no "resume returned is_error" \
        || ok "claude --resume coexists with --output-format json + --append-system-prompt"
      note "resume usage: $(printf '%s' "$raw2" | jq -c '.usage // "n/a"')"
      if [ "$DRY_RUN" != "1" ]; then
        cr="$(printf '%s' "$raw2" | jq -r '.usage.cache_read_input_tokens // 0')"
        it="$(printf '%s' "$raw2" | jq -r '.usage.input_tokens // 0')"
        case "$cr" in ''|*[!0-9]*) cr=0;; esac
        if [ "$cr" -gt 0 ]; then ok "cache DISCOUNT observed (cache_read=$cr vs input=$it)"
        else nodiscount=1; note "⚠ no cache_read_input_tokens on resume (=$cr) — no discount this run (cache window / TURN_SLEEP?)"; fi
      fi
    fi
  fi
fi

# ── codex: create, then resume ────────────────────────────────────────────────
echo; echo "== codex =="
printf '%s\n\n%s' "$XP" "Say hello to CLAUDE in one sentence." \
  | "$CODEX_BIN" exec - --json --skip-git-repo-check -o "$tmp/x1.out" -c sandbox_mode="read-only" \
      >"$tmp/x1.evt" 2>"$tmp/x1.err"; rcx=$?
tid="$(grep -o '"thread_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp/x1.evt" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$rcx" -ne 0 ]; then
  no "codex create failed (rc=$rcx): $(head -c 200 "$tmp/x1.err")"
else
  [ -n "$tid" ] && ok "codex --json emitted thread.started (thread_id=$tid)" \
                || no "no thread.started/thread_id in codex --json output — id capture would fail"
  [ -s "$tmp/x1.out" ] && ok "codex -o received the reply under --json" || no "codex -o file empty under --json"
  note "codex create event types: $(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp/x1.evt" | sort -u | tr '\n' ' ')"
  if [ -n "$tid" ]; then
    printf '%s\n\n%s' "$XP" "Reply to CLAUDE in one sentence." \
      | "$CODEX_BIN" exec resume "$tid" - --json --skip-git-repo-check -o "$tmp/x2.out" -c sandbox_mode="read-only" \
          >"$tmp/x2.evt" 2>"$tmp/x2.err"; rcx2=$?
    if [ "$rcx2" -ne 0 ]; then
      no "codex exec resume <id> REJECTED (rc=$rcx2): $(head -c 200 "$tmp/x2.err")"
      note "→ adapter would self-heal to stateless every turn (still correct, no saving)"
    else
      ok "codex exec resume <id> works"
      [ -s "$tmp/x2.out" ] && ok "codex resume -o received the reply" || no "codex resume -o empty"
      note "codex resume token/usage lines: $(grep -iE 'token|usage|cache' "$tmp/x2.evt" | head -3 | tr '\n' ' ' | head -c 300)"
    fi
  fi
fi

echo
if [ "$DRY_RUN" = "1" ]; then
  [ "$fail" -eq 0 ] && echo "✅ DRY_RUN plumbing OK — contracts exercised against mocks. Run RUN_REAL_CLI=1 for the real verdict." \
                     || { echo "❌ DRY_RUN plumbing broke — fix the harness before a real run."; exit 1; }
else
  if [ "$fail" -ne 0 ]; then
    echo "❌ a REAL-CLI CONTRACT FAILED (see ✗). The adapter self-heals to stateless, so it stays correct but saves nothing — update docs / the codex id-capture accordingly."; exit 1
  elif [ "$nodiscount" -ne 0 ]; then
    echo "⚠️  Contracts hold, but NO cache discount was observed this run. Keep TURN_SLEEP under the provider's cache window, or treat resume as a no-op saving and say so in the docs."
  else
    echo "✅ Contracts hold AND a cache discount was observed. The docs' 'verify before promising' note can be upgraded to a measured claim."
  fi
fi
