# codex-claude bridge

Make **Claude Code CLI** and **OpenAI Codex CLI** hold a conversation with each
other — using each tool's own subscription login, **no API keys, no token
extraction, no internal endpoints**.

This repo is being built in stages:

| Stage | What | Status |
|------|------|--------|
| **C** | Turn-taking orchestrator CLI (`bridge.sh`) | ✅ done |
| **A** | `file-watch → SSE` web dashboard (`dashboard/`) | ✅ done |
| **B** | WebSocket version where a human joins live | ⬜ optional |

## The one design idea worth knowing

There are **two transport layers**, and they want different mechanisms:

1. **Agent ↔ agent** — each turn is a single headless CLI call
   (`claude -p`, `codex exec`). The orchestrator drives the alternation, so
   this layer needs **no polling at all** — a blocking sequential loop *is* the
   synchronization.
2. **Backend → dashboard** — this is where the "polling dashboards" you've seen
   live. But because *we* own the writer, we don't need to poll: we can
   `file-watch` the log and **push** over SSE/WebSocket. Polling is only for
   observing a writer you *don't* control.

## Prerequisites

- `claude` (Claude Code) — logged in (`claude` → `/login`, Pro/Max plan)
- `codex` (`npm i -g @openai/codex`) — logged in (`codex login`, ChatGPT plan)
- `jq`

## Quick start

```bash
./bridge.sh "Let's design a tiny URL shortener. Keep replies under 80 words."
```

Watch the conversation stream to the terminal and to `conversation.jsonl`.

### Config (all env vars)

| var | default | meaning |
|-----|---------|---------|
| `MAX_TURNS` | `6` | total AI replies (excludes the human seed) |
| `TURN_SLEEP` | `6` | seconds between turns — **your rate-limit guard** |
| `TURN_TIMEOUT` | `180` | per-CLI-call timeout in seconds (needs `timeout`/`gtimeout`) |
| `CTX_MAX_TURNS` | `40` | only feed the last N turns as context |
| `CTX_MAX_BYTES` | `200000` | cap that context to N bytes |
| `FIRST_SPEAKER` | `claude` | `claude` or `codex` (case-insensitive) |
| `BRIDGE_LOG` | `conversation.jsonl` | output log path |
| `CLAUDE_BIN` / `CODEX_BIN` | `claude` / `codex` | binary paths (tests inject mocks here) |
| `CLAUDE_PERSONA` / `CODEX_PERSONA` | see script | system prompt + loop-back guard |

Example:

```bash
MAX_TURNS=4 TURN_SLEEP=10 FIRST_SPEAKER=codex \
  ./bridge.sh "Argue about tabs vs spaces, politely."
```

## Live dashboard (Stage A)

Watch the two agents talk in a browser — color-coded bubbles that update live
over Server-Sent Events (push, not polling; we own the writer). Zero
dependencies (Node built-ins only).

```bash
# terminal 1 — start the dashboard (defaults to ../conversation.jsonl, port 4100)
cd dashboard && node server.js
# open http://localhost:4100

# terminal 2 — run a conversation; bubbles stream into the open page
./bridge.sh "Argue about tabs vs spaces, politely."
```

Point it at a different log or port with `BRIDGE_LOG=/path/to.jsonl PORT=8080 node server.js`.
Test it (no browser, zero tokens): `node dashboard/test/sse_test.js`.

## Log format (`conversation.jsonl`)

One JSON object per line — this is the contract the dashboard will consume:

```json
{"ts":"2026-07-14T12:00:00Z","role":"human","text":"..."}
{"ts":"2026-07-14T12:00:07Z","role":"claude","text":"..."}
{"ts":"2026-07-14T12:00:15Z","role":"codex","text":"..."}
```

## Tests

```bash
./test/run_mock_test.sh    # happy path
./test/run_error_test.sh   # failure paths + security
```

Both run the **real** `bridge.sh` against **mock** CLIs (zero tokens).

- `run_mock_test.sh` — turn-taking, role tagging, JSONL shape, no-empty-replies,
  and that context accumulates across turns.
- `run_error_test.sh` — fail-loud on a CLI error / `is_error` envelope (aborts with
  a non-zero exit, never a fake success), no placeholder recycled into the log,
  prompt-injection is neutralized (an embedded newline can't forge a `human:`/`codex:`
  turn), and `CODEX_PERSONA` is actually delivered to codex.

## Fail-loud behavior

A CLI error, timeout, auth failure, rate-limit lockout, or `is_error` envelope
**aborts the run** with the real diagnostic on stderr and a **non-zero exit code**
— so a CI/cron/dashboard caller can tell a lockout from a healthy run. It never
prints `✅ done` on failure.

## ⚠️ Rate limits & terms

- Both platforms share a **5-hour rolling window + weekly cap** with their web
  apps. An unthrottled loop drains this fast — keep `MAX_TURNS` small and
  `TURN_SLEEP` generous.
- Headless use on your own single subscription, for personal use, is intended
  and supported. For anything **continuous / unattended / productized**, both
  vendors steer you to metered **API keys** instead — and never share accounts,
  route other users through your login, or extract/replay auth tokens.

## Implementation notes

- **Codex stdin-hang workaround**: the prompt is piped via `codex exec -`
  (stdin), so EOF arrives when the pipe closes — no hang. Claude gets the prompt
  as a positional arg with `< /dev/null` as a belt-and-suspenders guard.
- **Clean output capture**: `codex exec -o <file>` writes only the final
  assistant message; `claude -p --output-format json | jq -r .result` extracts
  just the text.
- **Loop-back prevention**: personas explicitly forbid each model from voicing
  the other; role tags keep turn ownership unambiguous.
- Stage C feeds the full transcript each turn (stateless, most portable). A
  later optimization is `--resume` (Claude) / `codex exec resume` (Codex) to
  keep context server-side and cut tokens.
