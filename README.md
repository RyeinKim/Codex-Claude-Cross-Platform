# codex-claude bridge

Make **Claude Code CLI** and **OpenAI Codex CLI** hold a conversation with each
other — using each tool's own subscription login, **no API keys, no token
extraction, no internal endpoints**.

This repo was built in stages, all of which are done:

| Stage | What | Status |
|------|------|--------|
| **C** | Turn-taking orchestrator CLI (`bridge.sh`, plus a `--once` single-turn mode) | ✅ done |
| **A** | `file-watch → SSE` view-only dashboard (`dashboard/server.js`, port 4100) | ✅ done |
| **B** | Interactive dashboard — human joins + drives it (`dashboard/live-server.js`, port 4200; SSE down, HTTP `POST /control` up — **no WebSocket**) | ✅ done |

## The one design idea worth knowing

There are **two transport layers**, and they want different mechanisms:

1. **Agent ↔ agent** — each turn is a single headless CLI call
   (`claude -p`, `codex exec`). The orchestrator drives the alternation, so
   this layer needs **no polling at all** — a blocking sequential loop *is* the
   synchronization.
2. **Backend → dashboard** — this is where the "polling dashboards" you've seen
   live. But because *we* own the writer, we don't need to poll: we can
   `file-watch` the log and **push** over SSE. Polling is only for observing a
   writer you *don't* control. Even the interactive Stage B needs no WebSocket:
   SSE pushes turns and state down; plain HTTP POST carries commands up.

## Prerequisites

- `claude` (Claude Code) — logged in (`claude` → `/login`, Pro/Max plan)
- `codex` (`npm i -g @openai/codex`) — logged in (`codex login`, ChatGPT plan)
- `jq` (the bridge exits `1` without it)
- Node **≥ 18** for the dashboards (zero npm dependencies — built-ins only)
- Optional but recommended: coreutils `timeout`/`gtimeout` so `TURN_TIMEOUT`
  is enforced (macOS: `brew install coreutils`); without it, turns are unbounded

## Quick start (loop mode)

```bash
./bridge.sh "Let's design a tiny URL shortener. Keep replies under 80 words."
```

Watch the conversation stream to the terminal and to `conversation.jsonl`.

> **Each loop-mode run truncates `conversation.jsonl`** before seeding the new
> topic (and the file is git-ignored). To keep a conversation, copy the file
> before the next run — or point `BRIDGE_LOG` at a fresh path per run.

### Config (all env vars)

| var | default | meaning |
|-----|---------|---------|
| `MAX_TURNS` | `6` | total AI replies (excludes the human seed) |
| `TURN_SLEEP` | `6` | seconds between turns — **your rate-limit guard** (no sleep after the last turn) |
| `TURN_TIMEOUT` | `180` | per-CLI-call timeout in seconds; enforced via `timeout`/`gtimeout` — if neither is on `PATH`, calls are **unbounded** (the startup banner says which) |
| `CTX_MAX_TURNS` | `40` | only feed the last N transcript lines as context |
| `CTX_MAX_BYTES` | `200000` | …then cap that context to N bytes |
| `FIRST_SPEAKER` | `claude` | `claude` or `codex` — **case-insensitive** (`CODEX` works); anything else exits `2` |
| `BRIDGE_TOPIC` | `Design a tiny URL shortener together. Keep each reply under 80 words.` | seed topic fallback — the CLI arg (`$1`) wins over it |
| `BRIDGE_LOG` | `conversation.jsonl` | shared JSONL log path |
| `CLAUDE_BIN` / `CODEX_BIN` | `claude` / `codex` | binary paths (the tests inject mocks here) |
| `CLAUDE_PERSONA` / `CODEX_PERSONA` | see script | system prompt + loop-back guard — each side is told NOT to voice the other |
| `BRIDGE_RESUME` | `0` | **opt-in, loop mode only**: `1` resumes each CLI's session and sends only the counterpart's latest message (a delta) instead of the full transcript. Off by default — see [Implementation notes](#implementation-notes) |

Example:

```bash
MAX_TURNS=4 TURN_SLEEP=10 FIRST_SPEAKER=codex \
  ./bridge.sh "Argue about tabs vs spaces, politely."
```

### `--once` — the single-turn contract

`bridge.sh --once <claude|codex>` runs **one** turn and nothing else. It is the
primitive the interactive server is built on, so personas, error handling, the
injection guard, and timeouts stay in one hardened place:

```bash
BRIDGE_LOG=conversation.jsonl ./bridge.sh --once codex   # one codex turn, to stdout
```

- **Reads** the existing log for context — no truncation, no topic seed, and it
  **never appends**: the reply goes to stdout (no trailing newline) and the
  *caller* decides whether to write it.
- The speaker is case-insensitive and defaults to `claude` if omitted.

Exit codes (both modes):

| code | meaning |
|------|---------|
| `0` | success — loop completed, or `--once` printed a reply |
| `1` | `jq` missing, or a turn failed (real diagnostic on stderr; loop mode keeps the partial log) |
| `2` | invalid `FIRST_SPEAKER` / invalid `--once` speaker |

## Live dashboard (Stage A — view only)

Watch the two agents talk in a browser — color-coded bubbles that update live
over Server-Sent Events. Zero dependencies (Node built-ins only).

```bash
# terminal 1 — start the dashboard (defaults to ../conversation.jsonl, port 4100)
cd dashboard && node server.js        # or: npm start
# open http://localhost:4100

# terminal 2 — run a conversation; bubbles stream into the open page
./bridge.sh "Argue about tabs vs spaces, politely."
```

| var | default | meaning |
|-----|---------|---------|
| `PORT` | `4100` | listen port |
| `HOST` | `127.0.0.1` | bind address — loopback only; don't expose the log over the LAN |
| `BRIDGE_LOG` | `<repo>/conversation.jsonl` | log file to stream |
| `BACKSTOP_MS` | `1000` | safety-poll interval (backstop only, see below) |

**Push, not poll**: the server `fs.watch`es the log's *directory* (so it
survives the file being truncated/recreated by a new run) and broadcasts each
new line over `GET /events` the moment it lands; the `BACKSTOP_MS` interval is
only a low-frequency backstop in case an fs event is ever missed. Each message
carries a synthesized `_i` (its line index) so the client can dedupe; when the
file shrinks — a new run truncated it — clients get a `reset` event and clear.
A connecting client gets the full backlog replayed synchronously *before* it's
registered for live pushes, so nothing is dropped or duplicated in between, and
`: ping` keep-alives go out every 25 s.

## Interactive mode (Stage B)

A control panel where **you join the conversation live** and drive it. Same
zero-dependency stack, but bidirectional: **SSE** (`GET /live-events`) pushes
turns + state to the browser, **`POST /control`** sends your commands back — no
WebSocket needed. Orchestration reuses `bridge.sh --once <speaker>`, and this
server is the **sole writer** of the log (don't run loop-mode `bridge.sh`
against the same `BRIDGE_LOG` while it's up).

```bash
cd dashboard && node live-server.js   # or: npm run start:live
# open http://localhost:4200
```

| var | default | meaning |
|-----|---------|---------|
| `PORT` | `4200` | listen port |
| `HOST` | `127.0.0.1` | bind address — loopback only; do **not** expose the control plane |
| `BRIDGE_LOG` | `<repo>/conversation.jsonl` | log file (server owns writes) |
| `BRIDGE_BIN` | `<repo>/bridge.sh` | path to the bridge script |

In the browser you can:

- **▶ Start** with a topic (empty topic → `Say hi and start chatting.`),
  **■ Stop**, or **⏭ Step** one turn at a time
- **Say** something mid-conversation — it's injected as a human turn and steered into the dialogue
- Live-tune the knobs: **delay** slider (0–30 s), **first/next speaker**,
  **max turns** (default `0` = unlimited — the auto-loop runs until you Stop)
- Read the status dot (live / busy-thinking / paused) and a server-driven AI-turn counter; errors appear as toasts

Command semantics (everything POSTs JSON to `/control`, is acknowledged
immediately with `{"ok":true}`, and runs through a **serialized queue** so
handlers never interleave; failures surface as SSE `error` events):

| command | what it does |
|---------|--------------|
| `start` | kills anything in flight, **truncates the log** (epoch+1, `reset` broadcast), seeds the topic as a human turn, applies `firstSpeaker`/`turnSleep`/`maxTurns`, auto-runs |
| `stop` | kills the in-flight `--once` child; a run-generation counter **drops its stale reply** — no ghost turn lands after Stop |
| `say` | always appends your text as a human turn immediately. Reply timing: **running** → picked up when the *next* turn's prompt is built (the in-flight turn was already prompted — inherent one-turn latency); **paused mid-turn** → one reply is owed and fires right after the current turn lands; **paused + idle** → exactly one AI reply now |
| `step` | one turn; only honored when paused and idle |
| `config` | live-updates `turnSleep` (clamped 0–300 s), `maxTurns` (clamped 0–100000, `0` = unlimited), `nextSpeaker` (a one-shot override that survives an in-flight turn) |
| `reset` | stop + truncate (epoch+1) *without* starting a new run |

Request bodies are capped at 1 MB; invalid JSON gets a `400`.

npm scripts (`dashboard/package.json`, node ≥ 18):

| script | runs |
|--------|------|
| `npm start` | `node server.js` (Stage A, :4100) |
| `npm run start:live` | `node live-server.js` (Stage B, :4200) |
| `npm test` | the three node suites (SSE push, interactive, cancellation) |

## Log format (`conversation.jsonl`)

One JSON object per line; `role` is `human`, `claude`, or `codex`. There are
**two record shapes**, depending on who wrote the line:

**Loop mode** (`bridge.sh`) writes the minimal record:

```json
{"ts":"2026-07-14T12:00:00Z","role":"human","text":"..."}
{"ts":"2026-07-14T12:00:07Z","role":"claude","text":"..."}
```

Stage A synthesizes `_i` from the line index at serve time (for client-side
dedupe) and signals truncation with a `reset` event.

**Live server** (Stage B, the sole writer) persists two extra fields:

```json
{"ts":"2026-07-14T12:00:07.123Z","role":"claude","text":"...","_i":12,"epoch":3}
```

- `_i` — a **monotonic message id, never reset** (not even across truncations),
  so a reconnecting client can dedupe the backlog replay without dropping or
  duplicating a single message.
- `epoch` — the **conversation generation**, bumped on every truncate
  (`start`/`reset`), so the client knows to clear the old conversation's DOM
  the moment records from a newer epoch arrive.

## Fail-loud behavior

**Bridge**: a CLI error, timeout, auth failure, rate-limit lockout, non-JSON
stdout, `is_error` envelope, or empty reply **aborts the run** with the real
diagnostic on stderr and a **non-zero exit code** — so a CI/cron/dashboard
caller can tell a lockout from a healthy run. It never prints `✅ done` on
failure and never writes placeholder text into the log.

**Interactive server**: a failed turn stops the run and pushes an SSE `error`
event carrying the real message (rendered as a toast). Stop/Start/Reset
**kill** the in-flight CLI process, and a run-generation counter discards its
now-stale reply so no ghost turn is appended. Log-write failures and unknown
commands are broadcast as `error` events too, and `unhandledRejection` /
`uncaughtException` handlers keep the sole log-writer/SSE process alive while
still announcing `internal error` — nothing fails silently.

## Tests

```bash
bash test/run_all.sh          # every suite, one command
./test/run_mock_test.sh       # bridge happy path
./test/run_error_test.sh      # bridge failure paths + security
./test/run_resume_test.sh     # opt-in BRIDGE_RESUME (loop mode)
cd dashboard && npm test      # the three node suites
```

All suites run the **real** `bridge.sh` / servers against **mock** CLIs in
`test/mocks/` — **zero real tokens**, no quota burned, no browser needed.

| suite | file | proves |
|-------|------|--------|
| bridge: happy path | `test/run_mock_test.sh` | 1 human seed + 4 strictly-alternating AI turns, correct role tags, valid JSONL, no empty replies, context **grows** across turns; `--once` prints one reply to stdout and **appends nothing** |
| bridge: failure + security | `test/run_error_test.sh` | non-zero exit on CLI failure and on `is_error` envelopes (never fake success), no placeholder recycled into the log, an embedded newline can't forge a `human:`/`codex:` turn, `CODEX_PERSONA` is actually delivered to codex |
| bridge: resume (opt-in) | `test/run_resume_test.sh` | `BRIDGE_RESUME=1` threads each CLI's session and sends a delta (not the full transcript), a fresh run resets it, codex uses `exec resume` read-only, personas still reach both sides, a stale session self-heals in one retry, a genuine error still aborts loud, and the injection guard collapses the delta |
| dashboard: SSE push | `dashboard/test/sse_test.js` | backlog replayed on connect, an appended line is pushed live via `fs.watch`, every message carries `_i` for dedupe |
| dashboard: interactive | `dashboard/test/live_test.js` | `start` seeds the topic then auto-runs, `maxTurns` halts the loop, a paused `say` injects a human turn **and** draws exactly one AI reply |
| dashboard: cancellation | `dashboard/test/live_cancel_test.js` | Stop during a slow in-flight turn kills the child and drops the stale reply — zero ghost turns in log or stream, state returns to idle |

Mock CLIs (`test/mocks/`): `mock-claude.sh` / `mock-codex.sh` (happy path —
each reply reports the prompt's byte count to prove context growth),
`fail-claude.sh` (simulated 429 lockout, exit 1), `error-claude.sh` (exit 0 but
an `is_error:true` envelope), `inject-claude.sh` (newline-forged
`human:`/`codex:` lines), `spy-codex.sh` / `spy-claude.sh` (record the exact
prompt / persona each CLI received), `slow-claude.sh` (sleeps so a test can
cancel it mid-turn), and the resume set — `resume-claude.sh` / `resume-codex.sh`
(echo a session id), `stale-claude.sh` / `genfail-claude.sh` (drive the
fail-loud retry paths), `noid-claude.sh` (resumes without returning a new id).

### Hardening provenance

This code went through **two adversarial review rounds** — on top of the
mock-tested loop, that's **three verification rounds** total (see
[ARCHITECTURE](docs/ARCHITECTURE.md#provenance-three-verification-rounds)):
9 confirmed findings against the bridge (fail-loud gaps, placeholder recycling,
prompt injection via embedded newlines, persona delivery, …) and 17 against the
interactive server
(double-start/TOCTOU races, ghost replies after Stop, unclamped inputs,
unhandled rejections, …). Every finding was fixed, and the classes of failure
are locked in by the suites above — `run_error_test.sh` names the bridge
findings it covers, and `live_cancel_test.js` covers the concurrency ones.

## Security notes

- Both servers bind **`127.0.0.1` by default and have no authentication** —
  do not set `HOST=0.0.0.0` or put them behind a proxy. Stage A would expose
  the transcript to the network; Stage B would expose a **control plane** that
  lets anyone start runs and burn your subscription quota.
- codex runs sandboxed: `codex exec --sandbox read-only --skip-git-repo-check`.
  claude's persona says "do not use any tools" and its stdin is `< /dev/null`.
- **Prompt-injection guard**: the transcript is flattened (`\n`/`\r` → space)
  before prompting, so a model reply can't forge a fake `human:`/`codex:` turn
  via an embedded newline. Locked in by `run_error_test.sh`.
- `POST /control` caps bodies at 1 MB and clamps/validates every input.

## ⚠️ Rate limits & terms

- Both platforms share a **5-hour rolling window + weekly cap** with their web
  apps — quota burned here is the *same pool* as your claude.ai / chatgpt.com
  usage. An unthrottled loop drains it fast: keep `MAX_TURNS` small and
  `TURN_SLEEP` generous.
- Headless use on your own single subscription, for personal use, is intended
  and supported. For anything **continuous / unattended / productized**, both
  vendors steer you to metered **API keys** instead — and never share accounts,
  route other users through your login, or extract/replay auth tokens.
- Note: if `ANTHROPIC_API_KEY` is exported, `claude -p` silently bills the
  **API** instead of your subscription — unset it unless that's what you want.

## Implementation notes

- **Codex stdin-hang workaround**: the prompt is piped via `codex exec -`
  (stdin), so EOF arrives when the pipe closes — no hang. Claude gets the prompt
  as a positional arg with `< /dev/null` as a belt-and-suspenders guard.
- **Clean output capture**: `codex exec -o <file>` writes only the final
  assistant message; `claude -p --output-format json | jq -r .result` extracts
  just the text.
- **Loop-back prevention**: personas explicitly forbid each model from voicing
  the other; role tags keep turn ownership unambiguous. (Codex has no
  `--append-system-prompt`, so its persona is prepended on stdin instead.)
- Stage C feeds the full (windowed) transcript each turn by default (stateless,
  most portable). Set `BRIDGE_RESUME=1` (loop mode only) to instead resume each
  CLI's own session (`claude -p --resume` / `codex exec resume`) and send only
  the counterpart's latest message; a resume failure retries once statelessly and
  then fails loud. NOTE: the payoff is a **prompt-cache discount, not a guaranteed
  token cut** — the CLIs still replay history locally, and the cache lapses when
  `TURN_SLEEP` exceeds the provider's short cache window, so verify with a
  real-CLI run (envelope usage fields) before relying on it. Stage B (interactive)
  still sends the full transcript.

## Repo layout

```
.
├── bridge.sh                  # Stage C — orchestrator (loop + --once modes)
├── conversation.jsonl         # shared log (git-ignored; truncated per run)
├── dashboard/
│   ├── server.js              # Stage A — view-only SSE dashboard (:4100)
│   ├── live-server.js         # Stage B — interactive dashboard (:4200)
│   ├── package.json           # npm start / start:live / test (node >= 18)
│   ├── public/
│   │   ├── index.html         # Stage A UI
│   │   └── live.html          # Stage B UI (controls + say composer)
│   └── test/
│       ├── sse_test.js        # Stage A push test
│       ├── live_test.js       # Stage B interactive test
│       └── live_cancel_test.js# Stage B cancellation test
└── test/
    ├── run_all.sh             # run all 5 suites
    ├── run_mock_test.sh       # bridge happy path
    ├── run_error_test.sh      # bridge failure + security
    └── mocks/                 # 7 mock CLIs (zero tokens)
```

## More docs

- [RUNBOOK.md](RUNBOOK.md) — day-2 operations: running, observing, recovering
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design deep-dive
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — symptoms → causes → fixes
