#!/usr/bin/env bash
#
# bridge.sh — Make Claude Code CLI and Codex CLI talk to each other.
#
# Pattern (C): a blocking, sequential turn-taking orchestrator.
#   - Each turn is ONE headless CLI invocation (claude -p / codex exec).
#   - The orchestrator drives the alternation, so there is NO polling here.
#   - Every turn is appended to a shared JSONL log (conversation.jsonl),
#     which a dashboard (pattern A) can later stream over SSE.
#
# Auth: uses each tool's own subscription login (Claude Pro/Max, ChatGPT
# Plus/Pro). No API keys, no token extraction, no internal endpoints.
#
# Rate limits are real: both platforms share a 5-hour window + weekly cap
# with their web apps. Keep MAX_TURNS small and TURN_SLEEP > 0.
#
# Fails loud: a CLI error / auth failure / rate-limit lockout aborts the run
# with a diagnostic on stderr and a non-zero exit code (never a fake success).
#
# Bash 3.2 compatible (macOS default).

set -uo pipefail

# ---- config (all env-overridable) ------------------------------------------
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
LOG="${BRIDGE_LOG:-conversation.jsonl}"
MAX_TURNS="${MAX_TURNS:-6}"          # total AI replies (excludes the human seed)
TURN_SLEEP="${TURN_SLEEP:-6}"        # seconds between turns (rate-limit guard)
TURN_TIMEOUT="${TURN_TIMEOUT:-180}"  # per-CLI-call timeout (needs timeout/gtimeout)
CTX_MAX_TURNS="${CTX_MAX_TURNS:-40}" # only feed the last N turns as context
CTX_MAX_BYTES="${CTX_MAX_BYTES:-200000}"  # and cap that context to N bytes
FIRST_SPEAKER="${FIRST_SPEAKER:-claude}"
# Opt-in (default OFF): 1 = each CLI resumes its own session so we send only the
# counterpart's latest message (a delta) instead of the full transcript every
# turn. LOOP MODE ONLY. When 0, every path below is byte-identical to before.
BRIDGE_RESUME="${BRIDGE_RESUME:-0}"

TOPIC="${1:-${BRIDGE_TOPIC:-Design a tiny URL shortener together. Keep each reply under 80 words.}}"

# Mode: default is the full loop. "--once <speaker>" runs a SINGLE turn against
# the existing log and prints the reply to stdout (no seed, no truncation) — the
# interactive server uses this so it reuses the hardened turn logic below.
MODE="loop"; ONCE_SPEAKER=""
if [ "${1:-}" = "--once" ]; then MODE="once"; ONCE_SPEAKER="${2:-claude}"; fi
# Resume is a LOOP-mode-only optimization. The interactive server spawns `--once`
# with the parent environment passed through, so an exported BRIDGE_RESUME must
# NOT change the single-turn primitive — force it off outside loop mode.
[ "$MODE" = "once" ] && BRIDGE_RESUME=0

# Personas double as loop-back guards: each side is told NOT to voice the other.
CLAUDE_PERSONA="${CLAUDE_PERSONA:-You are CLAUDE, in a conversation with another AI assistant named CODEX. Reply with exactly ONE short message, in your own voice as CLAUDE. Do NOT write lines for CODEX or roleplay CODEX. Do not use any tools; just talk.}"
CODEX_PERSONA="${CODEX_PERSONA:-You are CODEX, in a conversation with another AI assistant named CLAUDE. Reply with exactly ONE short message, in your own voice as CODEX. Do NOT write lines for CLAUDE or roleplay CLAUDE.}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# Normalize + validate the first speaker (case-insensitive).
FIRST_SPEAKER="$(printf '%s' "$FIRST_SPEAKER" | tr '[:upper:]' '[:lower:]')"
case "$FIRST_SPEAKER" in
  claude|codex) ;;
  *) echo "error: FIRST_SPEAKER must be 'claude' or 'codex' (got: $FIRST_SPEAKER)" >&2; exit 2;;
esac

# Optional timeout wrapper (prefer coreutils timeout/gtimeout when present).
TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
with_timeout() {
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$TURN_TIMEOUT" "$@"; else "$@"; fi
}

# Scratch files: one for each CLI's stderr, one for a captured session id
# (a turn runs in a command-substitution subshell, so it can't set a parent
# variable — it writes the new session id here and the loop reads it back).
ERRFILE="$(mktemp)"
SIDFILE="$(mktemp)"
trap 'rm -f "$ERRFILE" "$SIDFILE"' EXIT

# ---- helpers ----------------------------------------------------------------
now() { date -u +%FT%TZ; }

append() { # role text  ->  one JSONL line
  jq -nc --arg ts "$(now)" --arg role "$1" --arg text "$2" \
    '{ts:$ts, role:$role, text:$text}' >> "$LOG"
}

# Render the conversation as plain text. Newlines/CRs in a reply are collapsed
# to spaces so a model can't forge a fake "human:/codex:" turn via an embedded
# newline (prompt-injection guard). Windowed to the last N turns / N bytes.
render_ctx() {
  jq -r '.role + ": " + (.text | gsub("\n";" ") | gsub("\r";" "))' "$LOG" \
    | tail -n "$CTX_MAX_TURNS" \
    | tail -c "$CTX_MAX_BYTES"
}

build_prompt() { # speaker -> full prompt text for that speaker's next turn
  local upper
  upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  printf 'Conversation so far:\n%s\n\nYour turn as %s (one short message):' \
    "$(render_ctx)" "$upper"
}

# Incremental prompt for a RESUMED session: only the transcript lines AFTER this
# speaker's own last turn (the counterpart's latest message, plus any human
# interjection) — the session already holds the earlier context. Uses the SAME
# newline/CR collapse as render_ctx, so the injection guard still applies.
build_incr_prompt() { # speaker -> delta prompt text
  local upper delta
  upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  delta="$(jq -rs --arg me "$1" '
      . as $a
      | (reduce range(0; $a | length) as $i (-1; if $a[$i].role == $me then $i else . end)) as $last
      | $a[$last + 1:][]
      | .role + ": " + (.text | gsub("\n";" ") | gsub("\r";" "))' "$LOG")"
  printf 'New messages since your last turn:\n%s\n\nYour turn as %s (one short message):' \
    "$delta" "$upper"
}

# Each run_* echoes the reply to stdout and returns 0 on success. On any
# failure (non-zero exit, timeout, empty output, error envelope, non-JSON),
# it writes a diagnostic to stderr and returns non-zero — the caller aborts.

run_claude() { # $1 = prompt   $2 = optional resume session id
  local raw rc reply sid_out
  if [ -n "${2:-}" ]; then
    raw="$(with_timeout "$CLAUDE_BIN" -p --output-format json \
          --append-system-prompt "$CLAUDE_PERSONA" --resume "$2" "$1" < /dev/null 2>"$ERRFILE")"
  else
    raw="$(with_timeout "$CLAUDE_BIN" -p --output-format json \
          --append-system-prompt "$CLAUDE_PERSONA" "$1" < /dev/null 2>"$ERRFILE")"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "claude CLI exited $rc: $(head -c 500 "$ERRFILE")" >&2
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    echo "claude returned non-JSON stdout: $(printf '%s' "$raw" | head -c 500)" >&2
    return 1
  fi
  if [ "$(printf '%s' "$raw" | jq -r '.is_error // false')" = "true" ]; then
    echo "claude reported is_error: $(printf '%s' "$raw" | jq -r '.result // ""' | head -c 500)" >&2
    return 1
  fi
  reply="$(printf '%s' "$raw" | jq -r '.result // empty')"
  if [ -z "$reply" ]; then echo "claude returned an empty result" >&2; return 1; fi
  # Capture this session's id so the next claude turn can --resume it.
  if [ "$BRIDGE_RESUME" = "1" ]; then
    sid_out="$(printf '%s' "$raw" | jq -r '.session_id // empty')"
    [ -n "$sid_out" ] && printf '%s' "$sid_out" > "$SIDFILE"
  fi
  printf '%s' "$reply"
}

run_codex() { # $1 = prompt   $2 = optional resume session (thread) id
  local out evt rc reply sid_out=""
  out="$(mktemp)"
  # Persona is prepended on EVERY turn (codex exec has no --append-system-prompt
  # and does not persist a system prompt across resumes), then the prompt, via
  # stdin so EOF arrives cleanly (no stdin hang).
  if [ "$BRIDGE_RESUME" = "1" ]; then
    # --json makes codex emit its event stream (incl. the thread id) on stdout;
    # the reply still lands in -o. read-only rides -c on the resume subcommand
    # (which has no --sandbox flag); --ephemeral is never used (it would drop
    # the session we need to resume).
    evt="$(mktemp)"
    if [ -n "${2:-}" ]; then
      printf '%s\n\n%s' "$CODEX_PERSONA" "$1" \
        | with_timeout "$CODEX_BIN" exec resume "$2" - \
            --json --skip-git-repo-check -o "$out" -c sandbox_mode="read-only" \
            >"$evt" 2>"$ERRFILE"
    else
      printf '%s\n\n%s' "$CODEX_PERSONA" "$1" \
        | with_timeout "$CODEX_BIN" exec - \
            --json --skip-git-repo-check -o "$out" -c sandbox_mode="read-only" \
            >"$evt" 2>"$ERRFILE"
    fi
    rc=$?
    reply="$(cat "$out")"; rm -f "$out"
    # thread.started carries the (possibly re-minted) id for the next resume;
    # only persisted below, after the call is confirmed good.
    sid_out="$(grep -o '"thread_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$evt" \
                 | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    rm -f "$evt"
  else
    printf '%s\n\n%s' "$CODEX_PERSONA" "$1" \
      | with_timeout "$CODEX_BIN" exec - \
          --sandbox read-only --skip-git-repo-check -o "$out" \
          >/dev/null 2>"$ERRFILE"
    rc=$?
    reply="$(cat "$out")"; rm -f "$out"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "codex CLI exited $rc: $(head -c 500 "$ERRFILE")" >&2
    return 1
  fi
  if [ -z "$reply" ]; then
    echo "codex returned empty output: $(head -c 500 "$ERRFILE")" >&2
    return 1
  fi
  # Persist the captured thread id only now that the call succeeded.
  [ -n "$sid_out" ] && printf '%s' "$sid_out" > "$SIDFILE"
  printf '%s' "$reply"
}

# One loop turn. With resume ON and a known session id, sends only the delta and
# resumes; if that resume call fails, retries EXACTLY ONCE with the full
# transcript and no resume (a stale/expired session self-heals). A genuine error
# fails that retry too and propagates non-zero — fail-loud, no masking. Emits the
# reply on stdout; the new session id lands in SIDFILE for the caller to persist.
run_turn() { # $1 = speaker   $2 = current session id (may be empty)
  local speaker="$1" sid="$2" prompt reply rc
  if [ "$BRIDGE_RESUME" = "1" ] && [ -n "$sid" ]; then
    : > "$SIDFILE"
    prompt="$(build_incr_prompt "$speaker")"
    if [ "$speaker" = "claude" ]; then reply="$(run_claude "$prompt" "$sid")"; rc=$?
    else reply="$(run_codex "$prompt" "$sid")"; rc=$?; fi
    if [ "$rc" -eq 0 ]; then printf '%s' "$reply"; return 0; fi
    echo "resume failed for $speaker — retrying once without resume (stateless)" >&2
  fi
  : > "$SIDFILE"
  prompt="$(build_prompt "$speaker")"
  if [ "$speaker" = "claude" ]; then reply="$(run_claude "$prompt")"; rc=$?
  else reply="$(run_codex "$prompt")"; rc=$?; fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$reply"
}

# ---- single-turn mode (used by the interactive server) ----------------------
if [ "$MODE" = "once" ]; then
  ONCE_SPEAKER="$(printf '%s' "$ONCE_SPEAKER" | tr '[:upper:]' '[:lower:]')"
  case "$ONCE_SPEAKER" in
    claude|codex) ;;
    *) echo "error: --once requires 'claude' or 'codex' (got: $ONCE_SPEAKER)" >&2; exit 2;;
  esac
  once_prompt="$(build_prompt "$ONCE_SPEAKER")"
  if [ "$ONCE_SPEAKER" = "claude" ]; then
    reply="$(run_claude "$once_prompt")" || exit 1
  else
    reply="$(run_codex "$once_prompt")" || exit 1
  fi
  printf '%s' "$reply"
  exit 0
fi

# ---- main (loop mode) -------------------------------------------------------
: > "$LOG"
append human "$TOPIC"
echo "▶ topic  : $TOPIC"
echo "▶ log    : $LOG"
echo "▶ turns  : $MAX_TURNS   sleep: ${TURN_SLEEP}s   first: $FIRST_SPEAKER"
echo "▶ timeout: ${TURN_TIMEOUT}s $( [ -n "$TIMEOUT_BIN" ] && echo "(via $TIMEOUT_BIN)" || echo "(no timeout binary — unbounded)" )"

speaker="$FIRST_SPEAKER"
status=0
claude_sid=""   # per-speaker resume handles — empty until each side's first turn,
codex_sid=""    # and naturally reset by a fresh run (the log was truncated above).
for (( turn=1; turn<=MAX_TURNS; turn++ )); do
  if [ "$speaker" = "claude" ]; then cur_sid="$claude_sid"; else cur_sid="$codex_sid"; fi

  if ! reply="$(run_turn "$speaker" "$cur_sid")"; then
    echo "✖ turn $turn ($speaker) failed — aborting run." >&2; status=1; break
  fi

  # Persist the (possibly re-minted) session id this turn captured in SIDFILE.
  if [ "$BRIDGE_RESUME" = "1" ]; then
    new_sid="$(cat "$SIDFILE" 2>/dev/null)"
    if [ -n "$new_sid" ]; then
      if [ "$speaker" = "claude" ]; then claude_sid="$new_sid"; else codex_sid="$new_sid"; fi
    fi
  fi

  append "$speaker" "$reply"
  printf '\n[%d] %s:\n%s\n' "$turn" "$speaker" "$reply"

  if [ "$speaker" = "claude" ]; then speaker="codex"; else speaker="claude"; fi
  if [ "$turn" -lt "$MAX_TURNS" ]; then sleep "$TURN_SLEEP"; fi
done

echo
if [ "$status" -eq 0 ]; then
  echo "✅ done — $MAX_TURNS turns written to $LOG"
else
  echo "⚠️  run stopped early after a failed turn — see the error above. Partial log: $LOG" >&2
fi
exit "$status"
