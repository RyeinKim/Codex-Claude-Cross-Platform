# CLAUDE.md

Bridge that makes Claude Code CLI and Codex CLI talk to each other via a shared JSONL log
(`conversation.jsonl`), using each tool's subscription login. Bash orchestrator + two zero-dependency Node dashboards.

## Layout

```
bridge.sh                    # Stage C: turn-taking orchestrator (loop + --once), bash 3.2
dashboard/server.js          # Stage A: view-only SSE dashboard              (port 4100)
dashboard/live-server.js     # Stage B: interactive dashboard, SOLE log writer (port 4200)
dashboard/public/            # index.html (A), live.html (B)
dashboard/test/              # sse_test.js, live_test.js, live_cancel_test.js
test/run_all.sh              # runs all 5 suites (mocked, zero tokens)
test/run_mock_test.sh        # bridge happy path + --once
test/run_error_test.sh       # fail-loud + is_error + injection + persona delivery
test/mocks/                  # mock/fail/error/inject/spy/slow CLI stand-ins
docs/                        # ARCHITECTURE.md (en), TROUBLESHOOTING.md (ko)
```

## Commands

```bash
./bridge.sh "topic here"                          # loop: TRUNCATES log, seeds topic, alternates turns
MAX_TURNS=4 TURN_SLEEP=10 FIRST_SPEAKER=codex ./bridge.sh "topic"
./bridge.sh --once claude                         # one turn vs existing log -> stdout; never writes log
./bridge.sh --once codex                          # (speaker defaults to claude if omitted)

(cd dashboard && node server.js)                  # Stage A  http://127.0.0.1:4100   (npm start)
(cd dashboard && node live-server.js)             # Stage B  http://127.0.0.1:4200   (npm run start:live)
# Env: PORT, HOST, BRIDGE_LOG; Stage A also BACKSTOP_MS; Stage B also BRIDGE_BIN

bash test/run_all.sh                              # ALL tests; zero tokens; safe to run always
bash test/run_mock_test.sh                        # bridge happy path + --once
bash test/run_error_test.sh                       # fail-loud, is_error, injection, persona delivery
(cd dashboard && npm test)                        # the 3 node suites (ports 4199/4288/4291)
```

Bridge env knobs: `CLAUDE_BIN` `CODEX_BIN` `BRIDGE_LOG` `MAX_TURNS=6` `TURN_SLEEP=6` `TURN_TIMEOUT=180`
`CTX_MAX_TURNS=40` `CTX_MAX_BYTES=200000` `FIRST_SPEAKER=claude` `BRIDGE_TOPIC` `CLAUDE_PERSONA` `CODEX_PERSONA`.
Exit codes: 0 ok, 1 failed turn / missing jq, 2 bad speaker (FIRST_SPEAKER or --once arg).

## Hard invariants — do NOT break

- **Bash 3.2** (macOS default) for every `*.sh`: no `mapfile`, no associative arrays, no `${var,,}`.
- **Zero dependencies** in both dashboard servers: Node built-ins only (`http`, `fs`, `path`, `child_process`). No npm installs.
- **Fail loud**: never mask a CLI error; non-zero exit on any failed turn; never write placeholder text
  ("no output" etc.) to the log; diagnostics go to stderr.
- **live-server.js is the SOLE writer of the log.** It spawns `bash bridge.sh --once <speaker>`, which only
  READS the log for context. Never make `--once` append; never run loop-mode bridge.sh against the live
  server's `BRIDGE_LOG`.
- Live-server records carry a **monotonic `_i`** (never reset/recycled, even across truncations) and an
  **`epoch`** bumped on every truncation (`start`/`reset`). Clients dedupe by `_i` and clear DOM on epoch change.
- `render_ctx` in bridge.sh **must keep collapsing `\n` and `\r` to spaces** — it is the prompt-injection
  guard (blocks forged `human:` / `codex:` turns).
- Personas must reach **both** CLIs: claude via `--append-system-prompt "$CLAUDE_PERSONA"`,
  codex via `printf '%s\n\n%s' "$CODEX_PERSONA" "$prompt" | codex exec -` (codex has no such flag).
- `HOST` default stays `127.0.0.1` on both servers. No auth exists; exposing Stage B exposes the
  control plane (anyone could burn quota).
- **Subscription auth only**: never add API-key code paths, token extraction, or internal endpoints.
- Keep throttle defaults sane in examples: small `MAX_TURNS`, `TURN_SLEEP > 0` (both platforms share a
  5-hour window + weekly cap with their web apps).

## Testing rules

- Automated tests must **NEVER invoke the real `claude`/`codex` CLIs** — they cost subscription quota.
  Use/extend `test/mocks/` (injected via `CLAUDE_BIN`/`CODEX_BIN`) instead.
- Real-CLI verification is manual only, run deliberately by the user.
- New bridge behavior → cover in `test/run_mock_test.sh` or `test/run_error_test.sh`;
  new server behavior → add a `dashboard/test/*.js` suite and wire it into `test/run_all.sh` and
  the dashboard `npm test` script.
- `bash test/run_all.sh` must pass before any commit.

## Docs map — keep in sync

When changing any flag, command, port, env var, record shape, SSE event, or protocol, update ALL of:
`README.md` (en), `RUNBOOK.md` (ko), `docs/ARCHITECTURE.md` (en), `docs/TROUBLESHOOTING.md` (ko)
in the same change.

## Git

- Conventional commits (`feat:` `fix:` `test:` `docs:` `chore:` `refactor:`), one unit of work per commit.
- Branch per task: `feature/*` (also `fix/*`, `refactor/*`); never commit to main directly.
- Never commit `conversation.jsonl` (git-ignored; contains live conversation data).
