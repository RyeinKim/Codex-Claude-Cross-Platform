# RUNBOOK — 운영 가이드

macOS에서 이 저장소(Claude Code CLI ⇄ Codex CLI 브리지)를 직접 돌리는 사람을 위한 실행 순서 가이드입니다.

> **TL;DR — 가장 흔한 사용법 한 줄**
>
> ```bash
> cd /Users/wayne/claude/claude-project/codex-claude-cross-platform && ./bridge.sh "토론 주제를 여기에"
> ```
>
> 두 AI가 터미널에서 번갈아 대화하고, 전체 기록이 `conversation.jsonl`에 쌓입니다. (⚠️ 실행할 때마다 이 파일은 초기화됩니다 — 2번 참고)

---

## 0. 사전 확인

세 가지 CLI가 설치되어 있는지 확인합니다.

```bash
claude --version   # 예: 2.1.212 (Claude Code)
codex --version    # 예: codex-cli 0.144.3
jq --version       # 예: jq-1.6  — 없으면: brew install jq
```

`jq`가 없으면 `bridge.sh`가 `error: jq is required`를 내고 exit 1로 즉시 종료합니다.

**로그인 상태 확인** (브리지는 API 키가 아니라 각 CLI의 구독 로그인을 그대로 사용합니다):

```bash
# Codex — 로그인 상태 출력
codex login status

# Claude — 대화형으로 열어 /status 로 계정·플랜 확인 (로그인 안 되어 있으면 /login)
claude
```

- Claude: Pro/Max 플랜 계정으로 로그인되어 있어야 합니다.
- Codex: ChatGPT 플랜 계정으로 `codex login` 되어 있어야 합니다.

**Codex 계정 전환** (다른 ChatGPT 계정으로 바꿀 때):

```bash
codex logout && codex login
```

**선택 — 턴 타임아웃 활성화**: `TURN_TIMEOUT`(기본 180초)은 `timeout` 또는 `gtimeout` 바이너리가 있어야 동작합니다. 둘 다 없으면 턴이 무제한으로 매달릴 수 있습니다(배너에 `no timeout binary — unbounded` 표시).

```bash
brew install coreutils   # gtimeout 제공
```

---

## 1. 프로젝트 폴더로 이동

```bash
cd /Users/wayne/claude/claude-project/codex-claude-cross-platform
```

`./bridge.sh`는 상대경로이고 로그 기본값(`BRIDGE_LOG=conversation.jsonl`)도 현재 디렉터리 기준이라, 이 폴더 안에서 실행해야 스크립트도 찾고 로그도 제자리에 생깁니다.

---

## 2. 기본 티키타카 (터미널만)

```bash
./bridge.sh "Design a tiny URL shortener together. Keep each reply under 80 words."
```

인자를 생략하면 위 문장이 기본 주제로 쓰입니다(`BRIDGE_TOPIC` 환경변수로도 지정 가능; CLI 인자가 우선).

**터미널 출력 읽는 법:**

```
▶ topic  : <주제>
▶ log    : conversation.jsonl
▶ turns  : 6   sleep: 6s   first: claude
▶ timeout: 180s (via gtimeout)

[1] claude:
<claude의 응답>

[2] codex:
<codex의 응답>
...
✅ done — 6 turns written to conversation.jsonl
```

- `[N] speaker:` 블록이 AI 턴 하나씩입니다. 사람 시드(주제)는 로그에만 기록되고 번호에는 포함되지 않습니다.
- 실패하면 `✖ turn N (claude|codex) failed — aborting run.` 후 즉시 중단하고, stderr에 실제 진단(예: rate-limit 메시지)과 `⚠️  run stopped early … Partial log: conversation.jsonl`을 출력합니다. 가짜 성공은 절대 찍지 않습니다.
- exit code: `0` 성공 / `1` 턴 실패 또는 jq 없음 / `2` 잘못된 화자 값(`FIRST_SPEAKER` 또는 `--once` 인자).

**로그 위치와 형식**: `conversation.jsonl` (프로젝트 루트, 한 줄에 JSON 하나 — `{ts, role, text}`).

> ⚠️ **매 실행마다 로그가 초기화됩니다.** loop 모드는 시작 시 `conversation.jsonl`을 truncate(`: > "$LOG"`)합니다. 이전 대화를 보존하려면 다음 실행 전에 복사하거나, 실행마다 다른 로그 경로를 지정하세요. (`conversation.jsonl`은 `.gitignore`에 있어서 git도 저장해 주지 않습니다.)

```bash
# 방법 1 — 실행 전에 백업
cp conversation.jsonl "run-$(date +%Y%m%d-%H%M%S).jsonl"

# 방법 2 — 실행마다 별도 로그 파일
BRIDGE_LOG="run-$(date +%Y%m%d-%H%M%S).jsonl" ./bridge.sh "새 주제"
```

---

## 3. 노브 조절 (환경변수)

모두 환경변수로 덮어쓸 수 있습니다. 소스 기준(`bridge.sh`) 전체 목록:

| 변수 | 기본값 | 의미 |
|---|---|---|
| `MAX_TURNS` | `6` | AI 응답 총 횟수 (사람 시드 제외) |
| `TURN_SLEEP` | `6` | 턴 사이 대기 초 — rate-limit 가드 |
| `TURN_TIMEOUT` | `180` | CLI 호출당 타임아웃 초 (`timeout`/`gtimeout` 필요, 없으면 무제한) |
| `CTX_MAX_TURNS` | `40` | 프롬프트에 넣는 최근 턴 수 |
| `CTX_MAX_BYTES` | `200000` | 그 컨텍스트의 바이트 상한 |
| `FIRST_SPEAKER` | `claude` | 첫 화자 — `claude` 또는 `codex` (대소문자 무관, 그 외 값은 exit 2) |
| `BRIDGE_LOG` | `conversation.jsonl` | 공유 JSONL 로그 경로 |
| `BRIDGE_TOPIC` | (URL shortener 기본 문장) | CLI 인자가 없을 때의 주제 |
| `CLAUDE_BIN` / `CODEX_BIN` | `claude` / `codex` | 바이너리 경로 (테스트가 mock을 주입하는 지점) |
| `CLAUDE_PERSONA` / `CODEX_PERSONA` | 스크립트 참고 | 각자의 시스템 프롬프트 겸 루프백 가드 ("상대 대사를 쓰지 마라") |

인라인 예시:

```bash
# 짧고 빠르게: 4턴, 턴 사이 2초
MAX_TURNS=4 TURN_SLEEP=2 ./bridge.sh "탭 vs 스페이스, 정중하게 논쟁해줘"

# codex가 먼저 말하고, 느린 모델 대비 타임아웃 5분
FIRST_SPEAKER=codex TURN_TIMEOUT=300 ./bridge.sh "REST vs GraphQL 장단점"

# 긴 세션: 20턴, 여유 있는 간격, 별도 로그 파일
MAX_TURNS=20 TURN_SLEEP=15 BRIDGE_LOG="debate-$(date +%H%M%S).jsonl" ./bridge.sh "모놀리스 vs 마이크로서비스"
```

---

## 4. 뷰 대시보드 — Stage A (포트 4100)

브라우저에서 대화를 실시간 말풍선으로 보는 **읽기 전용** 대시보드입니다. 터미널 2개가 필요합니다.

**터미널 1 — 서버 기동** (프로젝트 루트에서):

```bash
node dashboard/server.js
# dashboard  → http://127.0.0.1:4100
# watching   → /Users/wayne/claude/claude-project/codex-claude-cross-platform/conversation.jsonl
```

브라우저에서 <http://localhost:4100> 을 엽니다. (대안: `cd dashboard && npm start`)

**터미널 2 — 대화 실행**:

```bash
cd /Users/wayne/claude/claude-project/codex-claude-cross-platform
./bridge.sh "Argue about tabs vs spaces, politely."
```

- 턴이 생길 때마다 SSE 푸시로 말풍선이 즉시 나타납니다(claude 보라/왼쪽, codex 초록/오른쪽, human 금색/가운데).
- 서버를 먼저 켜든 나중에 켜든 무관 — 접속 시 기존 로그 전체를 백로그로 재생합니다.
- 새 run이 시작되어 로그가 줄어들면(truncate) 화면을 자동으로 비우고 새 대화를 다시 스트림합니다.
- 다른 로그/포트: `BRIDGE_LOG=/path/to.jsonl PORT=8080 node dashboard/server.js`

---

## 5. 인터랙티브 대시보드 — Stage B (포트 4200)

사람이 대화에 직접 끼어들고 컨트롤하는 대시보드입니다. **터미널 1개**면 됩니다 — 턴 실행은 서버가 내부에서 `bridge.sh --once <speaker>`로 대신 돌립니다.

```bash
node dashboard/live-server.js
# interactive dashboard → http://127.0.0.1:4200
```

브라우저에서 <http://localhost:4200> 을 엽니다. (대안: `cd dashboard && npm run start:live`)

> ⚠️ Stage B 서버가 떠 있는 동안 같은 로그 파일에 loop 모드 `./bridge.sh`를 돌리지 마세요. 이 서버가 로그의 **유일한 작성자**여야 합니다(외부 기록은 실시간 반영도 안 되고, loop 모드가 서버 몰래 파일을 truncate합니다).

**화면 컨트롤:**

| 컨트롤 | 동작 |
|---|---|
| 주제 입력창 | 시작 주제. Enter를 치면 Start와 동일. 비워두면 `Say hi and start chatting.`이 시드로 들어감 |
| `▶ Start` | **로그를 초기화(truncate)하고** 주제를 human 턴으로 심은 뒤 자동 턴 루프 시작. 턴 생성 중(busy)에는 비활성 |
| `■ Stop` | 자동 루프 정지. **진행 중이던 턴은 즉시 kill**되고 그 응답은 버려짐(유령 턴 없음). 실행 중이 아닐 때 비활성 |
| `⏭ Step` | 일시정지 + 유휴 상태에서 딱 **한 턴**만 실행. 실행 중이거나 busy면 비활성 |
| `first` 셀렉트 | 다음 화자를 `claude`/`codex`로 강제. 진행 중인 턴이 있어도 "그 다음 턴"에 1회 적용됨 |
| `delay` 슬라이더 | 턴 사이 대기 0–30초 (서버는 0–300초로 클램프). 실행 중에도 변경 가능 |
| `max turns` 숫자 | AI 턴 수 상한. **`0` = 무제한** (서버 상한 100000). 도달하면 자동으로 멈춤 |
| Say 입력창 + `Send` | 사람 발언을 대화에 주입 (Enter로도 전송). 규칙은 아래 |
| 헤더 상태 점 | 초록 = 자동 실행 중(live) / 금색 = 턴 생성 중(…claude thinking) / 회색 = 일시정지(paused). 옆의 `N turns`는 AI 턴 카운트 |

**Say 동작 규칙 (3케이스):**

1. **자동 실행 중(running)** — 발언은 즉시 로그에 기록되지만, AI는 *다음 턴*의 프롬프트를 만들 때 읽습니다. 이미 진행 중인 턴에는 반영되지 않음 → **1턴 지연**은 구조상 당연한 동작.
2. **일시정지 상태인데 턴이 아직 진행 중(paused + busy)** — 현재 턴이 끝난 직후 **딱 1회** AI가 응답합니다(빚진 응답 1개만).
3. **일시정지 + 유휴(paused + idle)** — **즉시 딱 1회** AI가 응답하고 다시 멈춥니다.

> ⚠️ **Start는 매번 로그를 초기화합니다** (터미널 loop 모드와 동일). 보존이 필요하면 Start 전에 `cp conversation.jsonl 백업파일.jsonl` 하세요.

에러(레이트리밋, CLI 실패 등)는 화면 하단에 빨간 토스트로 뜨고 루프는 멈춥니다.

---

## 6. 테스트 (토큰 소모 0)

전체 스위트는 명령 하나로 — 실제 CLI 대신 mock을 쓰므로 구독 사용량을 전혀 쓰지 않습니다:

```bash
bash test/run_all.sh
# 끝에 ✅ ALL SUITES PASSED (실패 시 ❌ SOME SUITES FAILED + exit 1)
```

개별 스위트:

| 스위트 | 명령 | 검증 내용 |
|---|---|---|
| bridge: happy path | `bash test/run_mock_test.sh` | 턴 교대·역할 태그·JSONL 형식·빈 응답 없음·컨텍스트 누적·`--once` 모드 |
| bridge: failure + security | `bash test/run_error_test.sh` | fail-loud(비정상 종료)·`is_error` 봉투 거부·프롬프트 인젝션 가드·`CODEX_PERSONA` 전달 |
| dashboard: SSE push | `node dashboard/test/sse_test.js` | Stage A 백로그 재생 + 실시간 푸시 |
| dashboard: interactive | `node dashboard/test/live_test.js` | Stage B start/maxTurns/say 1회 응답 |
| dashboard: cancellation | `node dashboard/test/live_cancel_test.js` | Stop이 진행 중 턴을 kill — 유령 응답 없음 |

node 3종만 묶어 돌리기: `cd dashboard && npm test`

---

## 7. GitHub 업로드 (선택)

```bash
gh repo create codex-claude-cross-platform --private --source=. --push
```

`conversation.jsonl`, `*.log`, `node_modules/` 등은 `.gitignore`에 있어 올라가지 않습니다. (현재 작업 브랜치: `feature/orchestrator-core`)

---

## 8. 주의사항

- **사용량은 진짜로 닳습니다.** Anthropic·OpenAI 모두 **5시간 롤링 윈도우 + 주간 캡**을 웹앱(claude.ai / chatgpt.com)과 **공유**합니다. 여기서 태운 만큼 웹에서 쓸 양이 줄어듭니다. `MAX_TURNS`는 작게, `TURN_SLEEP`은 넉넉하게.
- **Stage B의 `max turns` 기본값은 `0` = 무제한.** Stop을 누르기 전까지 계속 돕니다. 값(예: 6)을 넣고 시작하는 습관을 권장합니다.
- **`HOST`를 외부에 노출하지 마세요.** 두 서버 모두 기본 `127.0.0.1`(loopback)이고 **인증이 전혀 없습니다.** `HOST=0.0.0.0`으로 띄우면 Stage A는 대화 로그가, Stage B는 컨트롤 플레인이 LAN에 통째로 노출됩니다 — 남이 내 구독 쿼터로 대화를 돌릴 수 있습니다.
- **ToS 경계**: 본인 단일 구독의 개인적 headless 사용까지가 의도된 범위입니다. **계정 공유, 다계정으로 캡 우회, 인증 토큰 추출/재사용 금지.** 지속적·무인·상용 워크로드는 종량제 API 키가 정석입니다.
- **`ANTHROPIC_API_KEY` 함정**: 이 변수가 셸에 설정되어 있으면 `claude -p`가 구독 로그인 대신 **API 키(종량 과금) 경로로 조용히 전환**됩니다. 구독 쿼터를 쓸 생각이면 실행 전에 `unset ANTHROPIC_API_KEY` 하세요. Stage B 서버는 `process.env`를 자식 `bridge.sh`에 그대로 물려주므로 서버를 띄우는 셸에도 똑같이 적용됩니다.
- `timeout`/`gtimeout`이 없으면 `TURN_TIMEOUT`이 무시되어 턴이 무한정 매달릴 수 있습니다(0번 참고).

---

## 9. 문제 발생 시

증상별 진단·해결은 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)를 보세요.
