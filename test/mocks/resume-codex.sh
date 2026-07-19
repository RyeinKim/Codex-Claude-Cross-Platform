#!/usr/bin/env bash
# Resume-aware mock of `codex exec [resume <id>] - --json ... -o <out> [-c ...]`.
# - Recognises the `exec resume <id>` subcommand form; on resume it echoes the
#   same thread_id back, on a fresh `exec -` it mints "codex-thread-1".
# - Under --json it emits a thread.started event on stdout (how bridge.sh
#   captures the id); the reply text still goes to the -o file.
# - Appends one line per call to $RESUME_LOG capturing the flags a test needs to
#   assert (mode, thread id, char count, --json, -c sandbox_mode, --skip-git-
#   repo-check, --ephemeral). Writes the received prompt to $CODEX_PROMPT_FILE.
set -u
mode="create"; rid=""; out=""; sawjson=0; sandbox="none"; skipgit=0; ephemeral=0
prev=""
for a in "$@"; do
  case "$prev" in
    resume) rid="$a";;
    -o) out="$a";;
    -c) case "$a" in sandbox_mode=*) sandbox="$a";; esac;;
  esac
  case "$a" in
    resume) mode="resume";;
    --json) sawjson=1;;
    --skip-git-repo-check) skipgit=1;;
    --ephemeral) ephemeral=1;;
  esac
  prev="$a"
done
prompt="$(cat)"
n=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
[ -n "${CODEX_PROMPT_FILE:-}" ] && printf '%s' "$prompt" > "$CODEX_PROMPT_FILE"
if [ "$mode" = "resume" ]; then tid="$rid"; else tid="codex-thread-1"; fi
[ -n "${RESUME_LOG:-}" ] && printf 'codex mode=%s tid=%s chars=%s json=%s sandbox=%s skipgit=%s ephemeral=%s\n' \
  "$mode" "$tid" "$n" "$sawjson" "$sandbox" "$skipgit" "$ephemeral" >> "$RESUME_LOG"
[ "$sawjson" = "1" ] && printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
reply="MOCK-CODEX reply (saw ${n} chars)"
if [ -n "$out" ]; then printf '%s\n' "$reply" > "$out"; else printf '%s\n' "$reply"; fi
