# Architecture

This document explains how the codex-claude bridge is designed, why each
mechanism was chosen, and where the sharp edges are. Ground truth is the code:
`bridge.sh`, `dashboard/server.js`, `dashboard/live-server.js`, and the test
suites under `test/` and `dashboard/test/`.

## Overview

The system makes **Claude Code CLI** (`claude`) and **OpenAI Codex CLI**
(`codex`) hold a conversation with each other, with a human able to watch and
join live from a browser. It is built in three stages:

| Stage | Component | Role |
|-------|-----------|------|
| C | `bridge.sh` | Blocking, sequential turn-taking orchestrator (loop mode) + hardened single-turn primitive (`--once`) |
| A | `dashboard/server.js` | View-only dashboard: watches the log, pushes turns to the browser over SSE (port 4100) |
| B | `dashboard/live-server.js` | Interactive dashboard: human joins and drives the run over SSE + `POST /control` (port 4200) |

All three share one contract: `conversation.jsonl`, an append-only JSONL log
with one message per line.

### Goals

- Use **only the official headless CLI surfaces**: `claude -p` and
  `codex exec`. No SDKs, no HTTP APIs, no internal endpoints.
- Authenticate with **each tool's own subscription login** (Claude Pro/Max,
  ChatGPT Plus/Pro). No API keys, **no token extraction or replay**.
- **Personal, single-account, single-machine** use. Access control is the
  loopback interface, not an auth layer.
- **Fail loud**: an auth failure, rate-limit lockout, timeout, or error
  envelope aborts with the real diagnostic on stderr and a non-zero exit —
  never a fake success, never a placeholder written into the log.
- Zero runtime dependencies beyond `bash`, `jq`, and Node built-ins
  (`engines: node >= 18`).

### Non-goals

- Multi-user or remote deployment (no auth, no TLS — by design).
- More than two agents.
- Conversation persistence across runs (each run truncates the log).
- Evading rate limits, sharing accounts, or productized/unattended operation
  (see [Rate limits & ToS](#rate-limits--tos-boundaries)).

## Component diagram

```
  topic (CLI arg / BRIDGE_TOPIC)          browser controls (Start/Stop/Step/Say/config)
        │                                        │
        ▼                                        ▼  POST /control (JSON)
┌────────────────────────┐            ┌─────────────────────────────────┐
│ Stage C: bridge.sh     │            │ Stage B: live-server.js  :4200  │
│  loop mode             │            │  serialized command queue       │
│  ─ truncate log        │            │  spawns per turn:               │
│  ─ seed human topic    │            │    bash bridge.sh --once <spkr> │◄─┐
│  ─ alternate turns     │            │  SOLE writer of the log         │  │
│     │                  │            └────────┬───────────▲────────────┘  │
│     ├─ claude -p …     │      append/truncate│           │ SSE           │
│     └─ codex exec - …  │                     ▼           │ /live-events  │
└───────────┬────────────┘         ┌──────────────────┐    │               │
            │ append               │conversation.jsonl│  browser: live.html│
            ▼                      │ (shared JSONL)   │  (control panel)   │
   {ts, role, text} per line       └──────┬───────────┘                    │
                                          │ read-only                      │
                     fs.watch + backstop  │  (--once reads context,        │
                                  ▲       │   never writes ───────────────┘
┌─────────────────────────────────┴───┐   │
│ Stage A: server.js  :4100           │◄──┘
│  pump(): detect new lines/shrink    │
│  GET /events (SSE push)             │
└──────────────┬──────────────────────┘
               │ SSE
               ▼
      browser: index.html (view-only bubbles)
```

Stage C loop mode and Stage B are alternative drivers of the same log — never
run both against the same `BRIDGE_LOG` (see
[sole-writer invariant](#sole-writer-invariant-and-the-out-of-band-writer-caveat)).
Stage A is a pure observer and can watch either.

## Transport analysis

There are two transport layers, and they want different mechanisms.

### (a) Agent ↔ agent: a blocking sequential loop — no polling

Each turn is **one headless CLI invocation** that blocks until the model
replies. The orchestrator alternates speakers; the blocking call *is* the
synchronization. There is nothing to poll: nobody else can produce a message
while a turn is in flight, because the orchestrator is the only party that
initiates turns (`bridge.sh` header: "The orchestrator drives the alternation,
so there is NO polling here").

Alternative agent-to-agent patterns, and when they would be right instead:

| Pattern | How it works | When it is the right choice |
|---------|--------------|------------------------------|
| **Blocking sequential loop** (chosen) | One owner process invokes each CLI in turn; the call blocks until the reply exists | Two parties, strict alternation, one machine, one owner process — this repo's exact shape |
| **Blocking MCP bridge** | One agent exposes the other as an MCP tool; agent A decides mid-reasoning to call "ask B" and blocks on the tool call | When the *agent* should decide when (and whether) to consult the other, instead of a fixed alternation imposed from outside |
| **Shared append-log / Git** | Each agent polls (or is webhooked from) a shared medium — a file, branch, or issue thread — and appends when it sees a message addressed to it | When the agents run on different machines, schedules, or owners and no single orchestrator controls both writers; asynchrony is inherent, so polling/watching becomes necessary |

### (b) Backend → browser: push, because we own the writer

The dashboards do **not** poll the log on behalf of the browser. Because *we*
own the writer (bridge.sh in Stage A's case; live-server itself in Stage B's),
the backend knows the moment a line lands:

- **Stage A**: `fs.watch` on the log's directory fires on append →
  `pump()` broadcasts the new lines over SSE. A low-frequency
  `setInterval(pump, BACKSTOP_MS)` (default 1000 ms) exists **only** as
  insurance against a missed fs event — it is a backstop, not the mechanism.
- **Stage B**: the server appends the record itself, so it broadcasts in the
  same call (`appendTurn` → `broadcast('message', rec)`). No watcher at all.

Polling is only correct when you are observing a writer you *don't* control.
The one polling loop that survives in this codebase — Stage A's backstop —
exists precisely because fs events are advisory, and it is deliberately slow.

## Turn lifecycle

Both loop mode and `--once` funnel through the same two functions,
`run_claude` and `run_codex` in `bridge.sh`. Persona delivery is
**asymmetric** because the two CLIs have different flag surfaces.

### One claude turn

1. `prompt="$(build_prompt claude)"` — render the windowed transcript (see
   [Prompt construction](#prompt-construction)).
2. Invoke (verbatim from `bridge.sh`):

   ```bash
   raw="$(with_timeout "$CLAUDE_BIN" -p --output-format json \
         --append-system-prompt "$CLAUDE_PERSONA" "$1" < /dev/null 2>"$ERRFILE")"
   ```

   - The persona rides the **`--append-system-prompt` flag**.
   - The prompt is a **positional argument**; `< /dev/null` is a
     belt-and-suspenders guard against a stdin hang.
   - `with_timeout` wraps the call in `timeout`/`gtimeout` with
     `TURN_TIMEOUT` (default 180 s). If **neither binary exists, the call is
     unbounded** and the startup banner says so
     (`(no timeout binary — unbounded)`).
3. Parse stdout as the documented JSON envelope; extract
   `jq -r '.result // empty'`.
4. **Fail paths** (each prints a diagnostic to stderr and returns non-zero;
   the caller aborts):
   | # | Condition | stderr diagnostic |
   |---|-----------|-------------------|
   | 1 | CLI exited non-zero (a `timeout` kill arrives here as exit 124) | `claude CLI exited $rc: <first 500 chars of stderr>` |
   | 2 | stdout is not JSON (`jq -e .` fails) | `claude returned non-JSON stdout: <first 500 chars>` |
   | 3 | envelope has `is_error: true` | `claude reported is_error: <first 500 chars of .result>` |
   | 4 | `.result` empty/missing | `claude returned an empty result` |

### One codex turn

1. `prompt="$(build_prompt codex)"`.
2. Invoke (verbatim):

   ```bash
   printf '%s\n\n%s' "$CODEX_PERSONA" "$1" \
     | with_timeout "$CODEX_BIN" exec - \
         --sandbox read-only --skip-git-repo-check -o "$out" \
         >/dev/null 2>"$ERRFILE"
   ```

   - `codex exec` has **no `--append-system-prompt`**, so the persona is
     **prepended to the prompt on stdin** (`persona\n\nprompt`), piped via
     `codex exec -` so EOF arrives cleanly when the pipe closes (no stdin
     hang).
   - The reply is read from the `-o "$out"` temp file — `codex exec -o <file>`
     writes **only the final assistant message**, so no transcript scraping is
     needed. stdout is discarded.
   - `--sandbox read-only` keeps codex from writing the workspace;
     `--skip-git-repo-check` lets it run outside a git repo.
3. **Fail paths**:
   | # | Condition | stderr diagnostic |
   |---|-----------|-------------------|
   | 1 | CLI exited non-zero (incl. timeout 124) | `codex CLI exited $rc: <first 500 chars of stderr>` |
   | 2 | output file empty | `codex returned empty output: <first 500 chars of stderr>` |

### Loop mode around the turn

```bash
./bridge.sh "Design a tiny URL shortener together. Keep each reply under 80 words."
```

- `: > "$LOG"` — **truncates the log at run start**, then seeds
  `append human "$TOPIC"`.
- `for (( turn=1; turn<=MAX_TURNS; turn++ ))`: build prompt → run turn →
  on success `append "$speaker" "$reply"` (`{ts, role, text}`,
  `ts = date -u +%FT%TZ`), echo `[N] speaker:` to the console, flip speaker,
  `sleep "$TURN_SLEEP"` (skipped after the last turn).
- On a failed turn: `✖ turn N (claude|codex) failed — aborting run.` on
  stderr, `status=1`, break; the run ends with
  `⚠️  run stopped early after a failed turn — see the error above. Partial log: $LOG`
  and `exit 1`. Success ends with `✅ done — $MAX_TURNS turns written to $LOG`.
  Nothing is ever written to the log for a failed turn.

### `--once` mode (the Stage B primitive)

```bash
BRIDGE_LOG=conversation.jsonl ./bridge.sh --once codex
```

- Validates the speaker (case-insensitively); anything but `claude`/`codex` →
  `error: --once requires 'claude' or 'codex' (got: …)` on stderr, **exit 2**.
- Builds the prompt from the **existing** log — no truncation, no seed.
- Runs exactly one turn; prints the raw reply to stdout with `printf '%s'`
  and exits 0. On turn failure: exit 1 (diagnostic already on stderr).
- **Never appends to the log.** The caller (live-server) owns the write.
  This is asserted by `test/run_mock_test.sh` ("--once does not append to the
  log (server is the sole writer)").

### Exit-code contract (`bridge.sh`)

| Code | Meaning |
|------|---------|
| `0` | Loop completed, or `--once` turn succeeded |
| `1` | `jq` missing; a turn failed (loop mode exits `$status`; `--once` exits via `|| exit 1`) |
| `2` | Invalid `FIRST_SPEAKER`; invalid `--once` speaker |

## Prompt construction

### `render_ctx` — the injection guard + windowing

```bash
render_ctx() {
  jq -r '.role + ": " + (.text | gsub("\n";" ") | gsub("\r";" "))' "$LOG" \
    | tail -n "$CTX_MAX_TURNS" \
    | tail -c "$CTX_MAX_BYTES"
}
```

Three properties, in order:

1. **Newline collapse (prompt-injection guard).** Every `\n` and `\r` inside
   a stored reply is replaced with a space before rendering. The transcript
   fed to a model is one line per turn, and the `role: ` prefix at
   line-start is written **only by the orchestrator**. A model that embeds
   `"\nhuman: SYSTEM OVERRIDE …"` in its reply cannot forge a turn — the
   forged line is flattened into the middle of its own message. Locked by the
   `[injection+persona]` case in `test/run_error_test.sh` (the spy prompt must
   contain exactly one `^human:` line and zero `^codex:` lines).
2. **Turn window**: `tail -n "$CTX_MAX_TURNS"` — only the last 40 turns
   (default) are fed forward.
3. **Byte cap**: `tail -c "$CTX_MAX_BYTES"` — then at most 200,000 bytes
   (default). Because this is a raw byte tail, the oldest surviving line may
   arrive truncated mid-line; that is an accepted cost of a cheap cap.

### `build_prompt` — the shape every model sees

```
Conversation so far:
human: <topic>
claude: <turn 1>
codex: <turn 2>

Your turn as CLAUDE (one short message):
```

(`printf 'Conversation so far:\n%s\n\nYour turn as %s (one short message):'`
with the speaker uppercased.) The personas — delivered out-of-band as
described above — double as **loop-back guards**: each side is explicitly told
not to write lines for, or roleplay, the other. Claude's persona additionally
says "Do not use any tools; just talk" (codex's does not need it — codex is
sandboxed `read-only` instead).

## Statelessness tradeoff

Stage C is **stateless per turn**: every invocation re-sends the full
(windowed) transcript. Costs and benefits:

- **Cost**: token usage grows roughly quadratically over a conversation —
  each turn re-pays for all prior turns (until the 40-turn / 200 KB window
  saturates and flattens it).
- **Benefit**: the JSONL log is the *only* state. No session-id bookkeeping,
  no dependency on either CLI's private session storage or its (unstable)
  schema, trivially crash-safe, and `--once` gets full context from a bare
  file — which is exactly what makes the Stage B server so simple.

Keeping context server-side is now an **opt-in for loop mode**: `BRIDGE_RESUME=1`
resumes each CLI's own session (`claude -p --resume <session-id>` /
`codex exec resume <thread-id>`) and sends only the newest message per turn. It
trades the above simplicity for a per-speaker session-id lifecycle — captured
from the claude `.session_id` envelope and the codex `--json` `thread.started`
event, held in shell scalars for the loop run, and reset whenever a fresh run
truncates the log. A resume call that fails retries **once** with the full
transcript and no resume, then fails loud: a stale session self-heals in that one
retry, while a genuine error survives it and aborts the run (never masked).

The default stays stateless (byte-identical), and **Stage B still re-sends the
full transcript** — extending resume to the sole-writer server (its own session
store keyed by epoch) is the deferred Phase 2. The saving is a **prompt-cache
discount**, now **verified on the real CLIs (2026-07-21)**: both resume contracts
hold (claude `--resume` coexists with `--output-format json` and returns
`.session_id`; codex `exec resume <id>` emits `thread.started` and accepts
`-c sandbox_mode=read-only`), and the resumed turn bills mostly from cache —
claude `input_tokens=2` / `cache_read_input_tokens=15289`, codex
`cached_input_tokens=29184` of `38890`. claude's cache is **1-hour** ephemeral
(more durable than the earlier ~5-min assumption); codex's window is shorter, so
keep `TURN_SLEEP` modest. This is a per-turn input discount confirmed on a short
probe — not an A/B measurement of the whole-conversation saving versus the
stateless path. Re-run `tools/verify_resume_real.sh` to reconfirm.

## Stage A mechanism (`dashboard/server.js`)

A ~115-line, zero-dependency observer. Key mechanics:

- **`fs.watch` on the directory, not the file**:
  `fs.watch(dir, (evt, fname) => { if (!fname || fname === base) pump(); })`.
  Watching the directory survives the file being re-created or truncated
  (loop mode does `: > "$LOG"` every run, which would strand an inode-level
  watcher). The whole watch setup is in a try/catch — if the directory does
  not exist yet, the backstop still covers it.
- **`BACKSTOP_MS` interval** (default 1000, env-overridable):
  `setInterval(pump, BACKSTOP_MS)` plus one initial `pump()`. Pure
  missed-event insurance.
- **Truncation → `reset`**: `pump()` stats the file; `if (size < lastSize)`
  the bridge started a new run — `sentCount` resets to 0 and every client gets
  an SSE `reset` event (data `{}`). The new run's lines then re-stream from
  index 0. Clients respond by wiping the DOM and their dedupe map.
- **Positional `_i`**: each broadcast line is
  `Object.assign({ _i: i }, lines[i])` — the index is **synthesized from the
  line's position in the file**, not persisted. The client dedupes with
  `seen[m._i]`, which resolves the overlap between the connect-time backlog
  replay and live pushes.
- **No-gap connect**: `pump()` and the `/events` handler both run
  synchronously on Node's single thread, so a connecting client replays the
  backlog (`_i` 0..K-1) *before* being pushed into `clients` — it gets K..
  from `pump()` with no gap and no duplicate.
- `readLines()` skips partial/unparseable lines (a write may be observed
  mid-append), keep-alive comment `: ping` every 25 s, `retry: 2000`
  reconnect hint, loopback binding, and a path-traversal guard (`403`) on the
  static file server.

## Stage B concurrency model (`dashboard/live-server.js`)

This is the load-bearing section. The server is a **single Node process that
is simultaneously the sole log writer, the SSE broadcaster, and the
orchestrator of child `bridge.sh --once` processes** — every mechanism below
exists to keep those three roles consistent under concurrent human input.

### Serialized command queue

```js
let cmdChain = Promise.resolve();
function enqueueCommand(cmd) {
  cmdChain = cmdChain.then(() => handleCommand(cmd)).catch((e) => broadcast('error', ...));
}
```

Every `POST /control` command — including the async ones (`start`, `stop`,
`reset` all `await` internal drains) — runs through **one promise chain**, so
command handlers never interleave. This kills the whole class of
double-`start` / TOCTOU races (two Starts racing to truncate the log, a Stop
landing between another handler's check and its act). The HTTP handler
responds `200 {"ok":true}` immediately after enqueueing
(fire-and-acknowledge); failures surface asynchronously as SSE `error`
events.

### Cancellation: child kill + `runGen` generation guard

```js
function cancelActive() { runGen++; if (currentChild) { try { currentChild.kill(); } catch (e) {} currentChild = null; } state.busy = false; }
```

An in-flight turn is a live `bash bridge.sh --once <speaker>` child tracked in
`currentChild`. `stop`/`reset`/`start` call `cancelActive()`, which does two
independent things:

1. **Kills the child.** In `runOnce`'s `close` handler, a signal-terminated
   child rejects with `new Error('turn cancelled')`.
2. **Bumps `runGen`.** `doTurn` captured `const gen = runGen` before
   spawning; after `runOnce` settles it checks `if (runGen !== gen) return false`
   — in the catch path (silent, no error broadcast for a cancellation) *and*
   after a successful resolve. The second check matters: if the reply resolved
   in the same tick the kill raced in, the now-stale reply is **dropped, not
   appended**. No ghost turn ever lands after Stop.

This is locked end-to-end by `dashboard/test/live_cancel_test.js`: a
2-second `slow-claude.sh` turn is started, `stop` is posted mid-flight, and
the test asserts zero AI turns were appended and the final state is idle.

### Epoch + monotonic `_i`: the reconnect/dedupe protocol

Stage B records are `{ts, role, text, _i, epoch}` (`appendTurn`):

- **`_i = nextId++`** — a monotonic message id, **persisted in the record and
  never reset**, not even across conversations. On boot, `initIds()` restores
  `nextId` as max(`_i`)+1 from any existing log (falling back to the record
  count for legacy records without `_i`).
- **`epoch`** — the conversation generation. `truncateLog()` empties the file
  and does `epoch++`; boot restores the max epoch found in the log.

The problem these solve: an SSE client that reconnects gets the **entire log
replayed as backlog** (records "already carry `_i` + epoch", so the server
replays them verbatim). Without persisted ids, the client cannot tell replayed
records from ones it already rendered — and if a truncation happened while it
was disconnected, positional indices would *collide* between the old and new
conversation, silently dropping new messages as "duplicates". Monotonic `_i`
makes `seen[_i]` dedupe correct across any number of reconnects; a record (or
`reset` event) carrying `epoch > currentEpoch` makes the client clear the old
conversation's DOM exactly once. (Stage A can get away with positional `_i`
only because its `reset` event and re-stream happen on one live connection.)

### `pendingReply`: a `say` that lands mid-turn while paused

`cmdSay` appends the human turn immediately, then routes:

| State | Behavior |
|-------|----------|
| `running` | Return — the loop's *next* prompt will include it (**inherent one-turn latency**: the in-flight turn's prompt was already built) |
| paused + `busy` (a Step/say turn is mid-flight) | `pendingReply = true` — the human is *owed one reply*; `stepOnce`'s trailing loop (`while (ok && !state.running && pendingReply && !state.busy)`) pays it right after the current turn resolves |
| paused + idle | `bg(stepOnce())` — exactly one AI reply |

`stopEverything()` (used by `start`/`reset`) clears `pendingReply`; plain
`stop` does not.

### `speakerOverride`: honoring a human choice across an in-flight turn

`config { nextSpeaker }` sets both `state.nextSpeaker` **and** a one-shot
`speakerOverride`. After a turn's reply lands, `doTurn` computes:

```js
state.nextSpeaker = speakerOverride || (speaker === 'claude' ? 'codex' : 'claude');
speakerOverride = null;
```

Without the override, a turn already in flight would clobber the user's
choice with the automatic flip when it completed. With it, the user's pick
survives the in-flight turn and then applies exactly once.

### Sole-writer invariant (and the out-of-band writer caveat)

**live-server.js is the sole writer of the log.** It has no `fs.watch` and no
backstop — it only broadcasts records it appended itself. The child it spawns
(`bridge.sh --once`) only *reads* the log for context (test-asserted). This
is what makes append + broadcast atomic from the clients' point of view.

The caveat: if anything else writes the same `BRIDGE_LOG` — above all,
loop-mode `bridge.sh` — those records are invisible to connected clients,
lack `_i`/`epoch` (poisoning dedupe and epoch-clearing on the next reconnect's
backlog replay), and loop mode's `: > "$LOG"` would truncate the file
underneath the server without bumping its epoch. **Never point loop-mode
`bridge.sh` at the live server's log.**

### Error containment layers

From innermost to outermost — the design goal is that the sole
log-writer/SSE process never dies and never fails silently:

1. `bridge.sh` fail-loud → `runOnce` rejects with the child's stderr (or
   `bridge --once <speaker> exited <code>`).
2. `doTurn` catch → `busy=false, running=false`, SSE `error` broadcast —
   unless the generation guard says it was a cancellation (silent).
3. `appendTurn` wraps `fs.appendFileSync`; a write failure broadcasts
   `log write failed: …` and the turn is treated as a failure (loop stops) —
   no silent loss.
4. `bg(p)` catches any background-task rejection (loop, step) → error
   broadcast + state reset.
5. `enqueueCommand`'s `.catch` broadcasts handler errors.
6. `process.on('unhandledRejection')` / `process.on('uncaughtException')`
   broadcast `internal error` and (for rejections) clear `busy`/`running` —
   the process stays up.

## Control protocol reference

### `POST /control`

- Body: JSON, capped at 1,000,000 bytes (`req.destroy()` beyond that).
- Unparseable JSON → `400` `bad json`.
- Anything parseable → `200` `{"ok":true}` immediately; outcomes and failures
  arrive as SSE events. Unknown `type` → SSE `error`
  `unknown command: <type>`.

| `type` | Fields | Semantics |
|--------|--------|-----------|
| `start` | `topic` string (default `Say hi and start chatting.`); `firstSpeaker` `"claude"`\|`"codex"`; `turnSleep` number; `maxTurns` number | Stop + kill anything in flight; **truncate log** (`epoch++`); broadcast `reset`; `turnCount=0`; clear `speakerOverride`; apply config; append the human topic; start the auto-loop |
| `stop` | — | Kill the in-flight child (stale reply dropped by the generation guard); stop the loop; state goes idle |
| `say` | `text` string (empty → no-op) | Append a human turn; then: running → picked up next turn; busy → `pendingReply`; paused+idle → exactly one AI reply |
| `step` | — | One AI turn, only if `!running && !busy`; otherwise ignored |
| `config` | `turnSleep`; `maxTurns`; `nextSpeaker` `"claude"`\|`"codex"` | Clamp + apply live; `nextSpeaker` also arms the one-shot `speakerOverride` |
| `reset` | — | Stop + **truncate log** (`epoch++`) + broadcast `reset`; does **not** start a new run |

Clamps: `turnSleep` → `[0, 300]` seconds; `maxTurns` → floored integer in
`[0, 100000]`, where **`0` means unlimited** (the loop check is
`state.maxTurns && state.turnCount >= state.maxTurns`). Non-finite input
keeps the current value.

Example:

```bash
curl -s -X POST http://127.0.0.1:4200/control \
  -H 'Content-Type: application/json' \
  -d '{"type":"start","topic":"debate tabs vs spaces","firstSpeaker":"claude","turnSleep":6,"maxTurns":8}'
```

### SSE event reference

Stage B — `GET /live-events`. On connect: `retry: 2000`, the **entire log
replayed as `message` events** (records already carry `_i`/`epoch`), then one
`state` event, then live events. Keep-alive comment `: ping` every 25 s.

| Event | Data fields | Notes |
|-------|-------------|-------|
| `message` | `ts` (ISO 8601), `role` (`human`\|`claude`\|`codex`), `text`, `_i` (monotonic int, never recycled), `epoch` (int) | One conversation record |
| `state` | `running`, `busy` (bool); `nextSpeaker` (`claude`\|`codex`); `turnSleep`, `maxTurns` (numbers); `turnCount` (AI replies only — human turns don't count); `epoch` | Broadcast on every state change |
| `reset` | `epoch` (the new epoch) | Log was truncated (`start`/`reset`); clients clear the old conversation |
| `error` | `message` (string) | Turn failure, log-write failure, unknown command, internal error |

Stage A — `GET /events`. Same headers/retry/ping; only two event types:

| Event | Data fields | Notes |
|-------|-------------|-------|
| `message` | `_i` (positional line index, not persisted), `ts`, `role`, `text` | Backlog on connect, then live pushes |
| `reset` | `{}` | File shrank — the bridge started a new run; lines re-stream from `_i` 0 |

## Security model

- **Loopback binding**: both servers default to `HOST=127.0.0.1`
  ("loopback only — don't expose the log over the LAN" /
  "do not expose the control plane"). Setting `HOST=0.0.0.0` would expose,
  respectively, the conversation log and — worse — a control plane that lets
  anyone on the network start runs and **burn your subscription quota**.
- **No auth, by design**: this is a personal single-user tool; the machine
  boundary is the access control. Do not port-forward or reverse-proxy it.
- **Codex is sandboxed**: every codex turn runs `--sandbox read-only` — an
  *enforced* CLI sandbox; it cannot write the workspace.
- **Claude is persona-restricted**: `CLAUDE_PERSONA` ends with "Do not use
  any tools; just talk." Note the honest asymmetry: this is an
  instruction-level guard, not an enforced sandbox.
- **Prompt-injection guard**: `render_ctx` collapses `\n`/`\r` in every stored
  reply, so model output cannot forge a `human:`/`codex:` line-start in the
  next prompt (test-locked).
- **Input validation**: speaker whitelists (`claude`|`codex`, else exit 2 /
  ignored), numeric clamps on `turnSleep`/`maxTurns`, 1 MB `/control` body
  cap, path-traversal guard (403) on both static servers.
- **Fail-loud guarantees**: non-zero exits with real diagnostics on stderr;
  errors broadcast as SSE `error` events; no placeholder text ever written to
  the log; the Stage B process survives internal errors (it must — it is the
  sole writer) but always announces them.

## Auth & accounts

- **Claude Code**: log in once interactively (`claude` → `/login`) on a
  Pro/Max plan. Headless `claude -p` reuses that stored login.
- **`ANTHROPIC_API_KEY` precedence pitfall**: if `ANTHROPIC_API_KEY` is set
  in the environment, `claude -p` silently uses **metered API-key billing**
  instead of the subscription login. The environment is inherited all the way
  down — live-server spawns the bridge with
  `Object.assign({}, process.env, { BRIDGE_LOG: LOG })` — so an exported key
  anywhere up the chain flips your billing. Unset it if you intend to burn
  subscription quota:

  ```bash
  unset ANTHROPIC_API_KEY
  ```

- **Codex CLI**: `npm i -g @openai/codex`, then `codex login` with a ChatGPT
  plan. Credentials land in `~/.codex/auth.json`; codex also writes
  per-session **rollout `.jsonl` files** under `~/.codex/` (what
  `codex exec resume` would replay). This repo never reads `auth.json`, never
  replays tokens, and never touches the rollout files — it only shells out to
  the logged-in CLI.
- **`~/.claude/projects`**: Claude Code keeps its own per-project JSONL
  transcripts there. Their **schema is unstable/undocumented**, which is
  exactly why this design does not parse them — the only Claude output
  surface used is the documented `-p --output-format json` envelope
  (`.result`, `.is_error`).
- Single account per tool, your own account only. No account sharing, no
  routing other users through your login.

## Rate limits & ToS boundaries

- **Rate limits are real and shared**: both platforms meter subscription
  usage in a **5-hour rolling window plus a weekly cap, shared with their web
  apps** (claude.ai / chatgpt.com). Quota burned by the bridge is the same
  quota as your interactive use. An unthrottled loop drains it fast.
- **How the design responds**:
  - `TURN_SLEEP` (default **6 s**) between turns — explicitly "your
    rate-limit guard"; Stage B exposes it as the delay slider (0–30 s in
    the UI; the server clamps `turnSleep` to 0–300 s) with an
    interruptible sleep.
  - `MAX_TURNS` (default **6**) bounds every loop run; Stage B's `maxTurns`
    (default **0** = unlimited) caps the auto-loop only when set to a
    positive value — otherwise it runs until Stop.
  - **Fail-loud on lockout**: a 429/auth failure aborts with the real
    diagnostic and a non-zero exit — the bridge never retries into a lockout
    and never masks one as success, so a caller (CI, cron, dashboard) can
    tell a lockout from a healthy run. Test-locked with a mock 429
    (`fail-claude.sh`).
- **ToS boundary**: headless use of your own single subscription for personal
  use is intended and supported. For anything **continuous, unattended, or
  productized**, both vendors steer you to metered **API keys** instead. Never
  share accounts, route other users through your login, extract/replay auth
  tokens, or run multiple accounts to evade caps. The loopback-only,
  no-auth deployment shape is the architectural expression of "personal,
  single account".

## Provenance: three verification rounds

Every hardening claim above is locked by a test that runs the **real**
scripts against **mock CLIs** — zero tokens (`bash test/run_all.sh` runs all
five suites).

1. **Mock-tested loop** (`test/run_mock_test.sh`, commit `83bf6ae`): the real
   `bridge.sh` against `mock-claude.sh`/`mock-codex.sh`. Asserts strict role
   alternation (`human,claude,codex,claude,codex`), JSONL shape, no empty
   replies, **context accumulation across turns** (the mocks echo how many
   prompt chars they saw), and `--once` semantics (prints one reply to
   stdout, never appends).
2. **Adversarial review round 1 — the bridge** (fixes shipped in commit
   `1ce05fa`, "Hardened per adversarial review"): **9 confirmed findings**
   against the orchestrator. The security-relevant ones are numbered in
   `test/run_error_test.sh`, which locks them:
   | Finding | Fix | Test assertion |
   |---------|-----|----------------|
   | #5 fail-loud | CLI error → abort, non-zero exit | rc ≠ 0; only the human seed in the log; real `429` diagnostic on stderr |
   | #6 `is_error` envelope | treated as failure, not conversation | envelope never recorded as a turn |
   | #8 placeholder recycling | no `"no output"` text ever written | `grep "no output"` finds nothing in the log |
   | #4 prompt injection | newline collapse in `render_ctx` | spy prompt has exactly 1 `^human:` and 0 `^codex:` lines |
   | #1 persona delivery | `CODEX_PERSONA` via stdin prepend | spy prompt contains `You are CODEX` |
   Other round-1 fixes visible in the code: the per-call timeout wrapper and
   context windowing.
3. **Adversarial review round 2 — the interactive server** (commit
   `4c1ff73`: "Adversarial review of Stage B confirmed **17 issues** (mostly
   concurrency)"). The fixes are the entire
   [Stage B concurrency model](#stage-b-concurrency-model-dashboardlive-serverjs):
   serialized command queue, kill + `runGen` guard, persisted monotonic
   `_i` + `epoch`, no unhandled rejections, loopback-only binding, input
   clamps, server-driven `turnCount`, honored `nextSpeaker`. Locked by
   `dashboard/test/live_test.js` (start/seed/auto-run, `maxTurns` stop,
   paused `say` draws exactly one reply, `_i` on every message) and
   `dashboard/test/live_cancel_test.js` (Stop mid-turn kills the child, **no
   ghost reply**, log holds only the seed, final state idle).

## Known limitations

- **One-turn latency for `say` while running.** The in-flight turn's prompt
  was built before your message existed; the *next* turn sees it. Inherent to
  building the full prompt up front.
- **Two agents only.** `claude`/`codex` are whitelisted everywhere (bridge
  exit 2 otherwise; server ignores other speakers) and alternation is a
  hardcoded binary flip.
- **No conversation persistence across runs.** Loop-mode start (`: > "$LOG"`)
  and Stage B `start`/`reset` truncate the log, and `conversation.jsonl` is
  git-ignored. Copy the file or point `BRIDGE_LOG` at a fresh path per run to
  keep a transcript.
- **No auth — local use only.** Remote/multi-user deployment is out of scope;
  exposing either port exposes the log (Stage A) or the quota-burning control
  plane (Stage B).
- **Unbounded turns without a timeout binary.** If neither `timeout` nor
  `gtimeout` is on `PATH`, `TURN_TIMEOUT` is a no-op (the banner warns). On
  macOS: `brew install coreutils`.
- **Stateless token cost by default.** The full windowed transcript is re-sent
  every turn unless `BRIDGE_RESUME=1` (loop mode only) resumes each CLI's session
  to send just a delta; Stage B always re-sends the full transcript. With resume
  the win is a **per-turn prompt-cache discount** — verified on real CLIs, but not
  an A/B measurement of the whole-conversation saving (see
  [Statelessness tradeoff](#statelessness-tradeoff)).
