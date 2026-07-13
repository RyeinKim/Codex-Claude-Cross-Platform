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

TOPIC="${1:-${BRIDGE_TOPIC:-Design a tiny URL shortener together. Keep each reply under 80 words.}}"

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

# Scratch file for capturing each CLI's stderr; cleaned up on exit.
ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT

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

# Each run_* echoes the reply to stdout and returns 0 on success. On any
# failure (non-zero exit, timeout, empty output, error envelope, non-JSON),
# it writes a diagnostic to stderr and returns non-zero — the caller aborts.

run_claude() { # $1 = prompt
  local raw rc reply
  raw="$(with_timeout "$CLAUDE_BIN" -p --output-format json \
        --append-system-prompt "$CLAUDE_PERSONA" "$1" < /dev/null 2>"$ERRFILE")"
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
  printf '%s' "$reply"
}

run_codex() { # $1 = prompt
  local out rc reply
  out="$(mktemp)"
  # Prepend the persona (codex exec has no --append-system-prompt), then the
  # transcript, all via stdin so EOF arrives cleanly (no stdin hang).
  printf '%s\n\n%s' "$CODEX_PERSONA" "$1" \
    | with_timeout "$CODEX_BIN" exec - \
        --sandbox read-only --skip-git-repo-check -o "$out" \
        >/dev/null 2>"$ERRFILE"
  rc=$?
  reply="$(cat "$out")"; rm -f "$out"
  if [ "$rc" -ne 0 ]; then
    echo "codex CLI exited $rc: $(head -c 500 "$ERRFILE")" >&2
    return 1
  fi
  if [ -z "$reply" ]; then
    echo "codex returned empty output: $(head -c 500 "$ERRFILE")" >&2
    return 1
  fi
  printf '%s' "$reply"
}

# ---- main -------------------------------------------------------------------
: > "$LOG"
append human "$TOPIC"
echo "▶ topic  : $TOPIC"
echo "▶ log    : $LOG"
echo "▶ turns  : $MAX_TURNS   sleep: ${TURN_SLEEP}s   first: $FIRST_SPEAKER"
echo "▶ timeout: ${TURN_TIMEOUT}s $( [ -n "$TIMEOUT_BIN" ] && echo "(via $TIMEOUT_BIN)" || echo "(no timeout binary — unbounded)" )"

speaker="$FIRST_SPEAKER"
status=0
for (( turn=1; turn<=MAX_TURNS; turn++ )); do
  prompt="$(build_prompt "$speaker")"

  if [ "$speaker" = "claude" ]; then
    if ! reply="$(run_claude "$prompt")"; then
      echo "✖ turn $turn (claude) failed — aborting run." >&2; status=1; break
    fi
  else
    if ! reply="$(run_codex "$prompt")"; then
      echo "✖ turn $turn (codex) failed — aborting run." >&2; status=1; break
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
