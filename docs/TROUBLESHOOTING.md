# 트러블슈팅 가이드

이 프로젝트의 모든 구성요소는 **fail-loud**로 설계되어 있다. 무언가 잘못되면
`bridge.sh`는 **stderr에 실제 진단을 출력하고 non-zero exit code로 즉시 중단**하며,
가짜 성공(`✅ done`)이나 placeholder를 로그에 남기지 않는다. 따라서 1차 진단은 항상:

```bash
./bridge.sh "테스트 주제"; echo "exit=$?"
```

stderr의 마지막 에러 메시지와 exit code를 먼저 확인한다.

### bridge.sh exit code 계약

| exit code | 의미 |
|---|---|
| `0` | 성공 (루프 완주 또는 `--once` 턴 성공) |
| `1` | `jq` 미설치(`error: jq is required`), 또는 턴 실패 (CLI 에러 / 타임아웃 / 레이트리밋 / 빈 응답 / `is_error` 응답) |
| `2` | 잘못된 `FIRST_SPEAKER` 값, 또는 잘못된 `--once` 스피커 (`claude`/`codex`만 허용) |

### 증상별 바로가기

| 증상 | 섹션 |
|---|---|
| `no such file or directory: ./bridge.sh` | [1](#1-no-such-file-or-directory-bridgesh) |
| `command not found: codex` / `codex CLI exited 127` | [2](#2-command-not-found-codex) |
| 레이트리밋/락아웃으로 실행 중단 | [3](#3-레이트리밋--락아웃) |
| `codex returned empty output` / 401 | [4](#4-codex-빈-출력--401) |
| 구독인데 API 요금이 청구됨 | [5](#5-anthropic_api_key-함정-구독-대신-api-과금) |
| 턴이 끝나지 않고 무한 대기 | [6](#6-타임아웃이-안-걸리고-무한-대기) |
| `EADDRINUSE` 포트 사용 중 | [7](#7-포트-사용-중-eaddrinuse) |
| 대시보드가 갱신되지 않음 | [8](#8-대시보드가-갱신되지-않음) |
| 어느 codex 계정으로 로그인됐는지 모름 | [9](#9-codex-로그인-계정-확인--계정-전환) |
| 이전 대화가 사라짐 | [10](#10-대화가-사라짐-로그-보존) |
| 원본 세션 기록을 직접 보고 싶음 | [11](#11-원본-세션-파일-위치claude--codex) |
| 테스트 실패 | [12](#12-테스트-실패-시-읽는-법) |
| live 대시보드에 중복/유령 메시지 | [13](#13-live-대시보드-이상-중복--유령-메시지) |
| `BRIDGE_RESUME` 세션 만료 / 토큰 절감이 없음 | [14](#14-bridge_resume-세션-만료--토큰-절감-확인) |

---

## 1. `no such file or directory: ./bridge.sh`

**증상**

```
zsh: no such file or directory: ./bridge.sh
```

**원인** — 프로젝트 루트가 아닌 디렉토리에서 상대 경로로 실행했다.

**해결** — 프로젝트 폴더로 이동한 뒤 실행한다.

```bash
cd /Users/wayne/claude/claude-project/codex-claude-cross-platform
./bridge.sh "주제"
```

`BRIDGE_LOG` 기본값(`conversation.jsonl`)은 **실행한 디렉토리 기준 상대 경로**이므로,
다른 곳에서 절대 경로로 스크립트만 실행하면 로그가 엉뚱한 곳에 생긴다
([8번 섹션](#8-대시보드가-갱신되지-않음) 참고). 루트에서 실행하는 습관이 가장 안전하다.

---

## 2. `command not found: codex`

**증상**

```
zsh: command not found: codex
```

또는 bridge 실행 중 stderr에:

```
codex CLI exited 127: ...
```

(127 = 셸이 바이너리를 찾지 못함. `claude`가 없으면 `claude CLI exited 127`.)

**원인** — `codex`는 npm 글로벌 패키지(`@openai/codex`)로, nvm을 쓰면 **노드 버전별
글로벌 bin 디렉토리**(예: `~/.nvm/versions/node/v22.14.0/bin/codex`)에 설치된다.
노드 버전을 바꿨거나, nvm 초기화가 안 된 셸(비로그인 셸, cron 등)에서는 PATH에 없다.

**해결**

```bash
which codex || echo "MISSING"

# nvm 사용 시: codex를 설치했던 노드 버전을 활성화
nvm use default

# 또는 현재 노드 버전에 재설치
npm i -g @openai/codex
codex --version
```

PATH를 건드리기 싫으면 bridge에 절대 경로를 직접 주입해도 된다
(테스트가 mock을 주입하는 것과 같은 메커니즘):

```bash
CODEX_BIN="/full/path/to/codex" CLAUDE_BIN="/full/path/to/claude" ./bridge.sh "주제"
```

---

## 3. 레이트리밋 / 락아웃

**증상** — 실행이 중간에 멈추고 stderr에 아래와 같은 시퀀스가 찍힌다
(bridge는 fail-loud — 재시도하지 않고 **즉시 중단**한다):

```
claude CLI exited 1: ...429...
✖ turn 3 (claude) failed — aborting run.

⚠️  run stopped early after a failed turn — see the error above. Partial log: conversation.jsonl
```

exit code는 `1`. CLI가 exit 0이면서 에러 봉투를 반환하는 경우에는 대신:

```
claude reported is_error: RATE LIMIT: retry after 3600s
```

codex 쪽 락아웃이면 `codex CLI exited <rc>: ...` 또는
`codex returned empty output: ...` 형태다. 어느 경우든:

- stderr 진단에는 **CLI가 뱉은 실제 에러의 첫 500바이트**가 그대로 포함된다
  (429, quota, retry-after 등).
- 로그(`conversation.jsonl`)에는 **성공한 턴까지만** 기록된다. placeholder나 가짜
  응답은 절대 기록되지 않는다.
- Stage B(live-server)에서는 같은 실패가 SSE `error` 이벤트 → 화면의 빨간 토스트로
  표시되고 실행이 자동 정지된다(`running=false`).

**원인** — Claude(Pro/Max)와 ChatGPT(Plus/Pro) 구독 모두 **웹앱과 공유하는 5시간
롤링 윈도우 + 주간 캡**이 있다. 스로틀 없는 루프는 이 한도를 빠르게 소진한다.
여기서 쓰는 quota는 claude.ai / chatgpt.com에서 쓰는 것과 **같은 quota**다.

**해결**

1. 5시간 윈도우가 풀릴 때까지 대기한다 (주간 캡에 걸렸다면 더 길다).
2. 재개할 때는 턴 수를 줄이고 턴 간격을 늘린다:

```bash
MAX_TURNS=4 TURN_SLEEP=20 ./bridge.sh "주제"
```

(`MAX_TURNS` 기본 6 = 전체 AI 응답 수, `TURN_SLEEP` 기본 6초 = 턴 사이 대기 —
레이트리밋 가드다. **줄일 것**은 `MAX_TURNS`, **늘릴 것**은 `TURN_SLEEP`.)

캡 회피 목적의 다중 계정 돌려쓰기, 계정 공유, 토큰 추출/재사용은 양쪽 약관 위반이다.
연속적/무인/제품화 용도라면 구독이 아니라 종량제 API 키를 쓰라는 것이 양사 방침이다.

---

## 4. codex 빈 출력 / 401

**증상**

```
codex returned empty output: ...
```

또는 stderr에 `401` / 인증 관련 메시지와 함께 `codex CLI exited <rc>: ...`.

**원인** — codex 인증이 만료됐거나 로그아웃된 상태다. bridge는 codex의 최종 응답을
`codex exec -o <임시파일>`로 받는데, 인증 실패 시 이 파일이 비어 fail-loud로 중단된다.

**해결**

```bash
codex login status          # 현재 인증 상태 확인
codex login                 # 재인증 (브라우저 열림, ChatGPT 계정으로 로그인)
```

깨끗하게 다시 하려면:

```bash
codex logout && codex login
```

이후에도 실패하면 bridge와 동일한 형태로 codex 단독 스모크 테스트를 해 본다:

```bash
echo "say hi" | codex exec - --sandbox read-only --skip-git-repo-check
```

---

## 5. `ANTHROPIC_API_KEY` 함정 (구독 대신 API 과금)

**증상** — bridge는 잘 도는데 Anthropic 콘솔에 **API 사용 요금**이 쌓인다.
구독(Pro/Max) 사용량 창은 움직이지 않는다.

**원인** — `claude` CLI는 환경변수 `ANTHROPIC_API_KEY`가 설정되어 있으면 구독 로그인
대신 **API 키(종량 과금) 경로를 조용히 사용**한다. bridge.sh와 live-server.js는 부모
프로세스의 환경을 그대로 상속하므로(live-server는 `Object.assign({}, process.env, ...)`로
bridge를 spawn), 셸 rc 파일에 export된 키가 그대로 전파된다.

**해결**

```bash
env | grep -i anthropic       # 설정 여부 확인
unset ANTHROPIC_API_KEY       # 현재 셸에서 제거
```

영구 제거는 `~/.zshrc` / `~/.zprofile` / `~/.zshenv`에서
`export ANTHROPIC_API_KEY=...` 줄을 지우고 새 셸을 연다.
구독 quota를 쓸 의도라면 이 변수는 항상 비워 둔다.

---

## 6. 타임아웃이 안 걸리고 무한 대기

**증상** — 한 턴이 몇 분째 끝나지 않는다. 시작 배너를 보면:

```
▶ timeout: 180s (no timeout binary — unbounded)
```

**원인** — `TURN_TIMEOUT`(기본 180초)은 `timeout` 또는 `gtimeout` 바이너리가 있어야
동작한다 (bridge는 `timeout` → `gtimeout` 순으로 찾는다). 둘 다 없으면 bridge는 CLI
호출을 **무제한으로** 실행한다. macOS 기본 설치에는 둘 다 없다.

**해결**

```bash
brew install coreutils        # gtimeout 제공
command -v timeout gtimeout   # 설치 확인 (하나만 있어도 충분)
```

다시 실행해서 배너가 다음처럼 바뀌면 정상이다:

```
▶ timeout: 180s (via gtimeout)
```

(`timeout`이 잡히는 환경이면 `(via timeout)`.) 타임아웃으로 죽은 턴은 GNU timeout의
kill exit code 124를 따라 `claude CLI exited 124: ...` 경로로 fail-loud 처리된다.
이미 무한 대기에 걸린 프로세스는 `Ctrl-C`로 끊으면 된다 — 로그에는 성공한 턴까지만
남아 있다.

---

## 7. 포트 사용 중 (`EADDRINUSE`)

**증상**

```
Error: listen EADDRINUSE: address already in use 127.0.0.1:4100
```

(Stage B는 `...:4200`.)

**원인** — 이전 대시보드 서버 프로세스가 아직 살아 있다.

**해결**

```bash
lsof -ti tcp:4100 | xargs kill      # Stage A (view-only, server.js)
lsof -ti tcp:4200 | xargs kill      # Stage B (interactive, live-server.js)
```

또는 다른 포트로 띄운다:

```bash
PORT=8080 node dashboard/server.js
```

참고: 테스트 스위트는 포트 4199(SSE) / 4288(interactive) / 4291(cancellation)을 쓴다.
테스트가 `EADDRINUSE`로 실패하면 같은 방법으로 해당 포트를 정리한다.

---

## 8. 대시보드가 갱신되지 않음

**증상** — bridge가 터미널에서 잘 돌고 있는데 브라우저(4100/4200)에 메시지가 안 뜬다.

**원인** — **서버와 bridge가 서로 다른 로그 파일을 보고 있다.** 기본값이 서로 다르게
해석되기 때문에 생기는 문제다:

- `dashboard/server.js` / `live-server.js`의 기본 로그: **저장소 루트의 절대 경로**
  (`<repo>/conversation.jsonl` — `path.join(ROOT, 'conversation.jsonl')`)
- `bridge.sh`의 기본 로그: **실행한 디렉토리 기준 상대 경로** (`conversation.jsonl`)

bridge를 다른 cwd에서 실행했거나, 한쪽에만 `BRIDGE_LOG`를 지정하면 어긋난다.
Stage A 서버는 `fs.watch` + 백스톱 폴링(기본 1초, `BACKSTOP_MS`)으로 파일을 감시하므로,
같은 파일만 보고 있다면 갱신이 1초 이상 늦을 일이 없다.

**해결**

1. 서버 부팅 로그에서 어느 파일을 보는지 확인한다:

   ```
   watching   → /Users/wayne/claude/claude-project/codex-claude-cross-platform/conversation.jsonl
   ```

   bridge 쪽은 시작 배너의 `▶ log    : ...` 줄과 비교한다 (상대 경로면 cwd 기준).

2. 둘 다 저장소 루트에서 실행하거나, 양쪽에 **같은 절대 경로**를 지정한다:

   ```bash
   LOGPATH=/Users/wayne/claude/claude-project/codex-claude-cross-platform/conversation.jsonl
   BRIDGE_LOG="$LOGPATH" node dashboard/server.js      # 터미널 1
   BRIDGE_LOG="$LOGPATH" ./bridge.sh "주제"            # 터미널 2
   ```

3. `BRIDGE_LOG`는 서버 부팅 시 한 번 읽히므로, 값을 바꿨다면 **서버를 재시작**한다:

   ```bash
   lsof -ti tcp:4100 | xargs kill
   BRIDGE_LOG="$LOGPATH" node dashboard/server.js
   ```

주의: Stage B(live-server)는 **자신이 로그의 유일한 writer**라는 전제로 동작하며
파일 감시를 하지 않는다. live-server가 쓰는 로그에 루프 모드 `bridge.sh`를 같이
돌리면 안 된다([13번 섹션](#13-live-대시보드-이상-중복--유령-메시지) 참고).

---

## 9. codex 로그인 계정 확인 / 계정 전환

**증상** — 여러 ChatGPT 계정을 쓰는데 지금 `codex`가 어느 계정/플랜으로 로그인됐는지
모르겠다 (quota가 예상보다 빨리 닳는 경우 포함).

**원인** — `codex login`은 `~/.codex/auth.json`에 토큰을 저장하며, 그 안의
`tokens.id_token`(JWT)에 계정 이메일과 플랜이 들어 있다.

**해결** — 우선 CLI가 알려주는 상태를 확인한다:

```bash
codex login status
```

이메일/플랜을 직접 보려면 JWT payload만 로컬에서 디코드한다 (외부 전송 없음):

```bash
python3 - <<'EOF'
# codex 로그인 계정 확인 — id_token의 payload(클레임)만 로컬에서 디코드한다.
# 주의: 토큰 원문(id_token/access_token/refresh_token)은 절대 출력·복사·공유하지 말 것.
import json, base64, pathlib
auth = json.loads((pathlib.Path.home() / ".codex" / "auth.json").read_text())
payload = auth["tokens"]["id_token"].split(".")[1]
payload += "=" * (-len(payload) % 4)          # base64url 패딩 보정
claims = json.loads(base64.urlsafe_b64decode(payload))
print("email:", claims.get("email"))
print("plan :", claims.get("https://api.openai.com/auth", {}).get("chatgpt_plan_type"))
EOF
```

출력 예: `email: you@example.com` / `plan : plus`.

**계정 전환 절차**

```bash
codex logout              # 저장된 인증 제거
codex login               # 브라우저에서 원하는 계정으로 로그인
codex login status        # 확인 (위 스니펫으로 email/plan 재확인)
```

주의: 캡 회피 목적의 다중 계정 돌려쓰기, 계정 공유, 토큰 추출/재사용은 양쪽 약관
위반이다. 이 프로젝트는 본인 단일 구독의 개인적 사용만 전제로 한다.

---

## 10. 대화가 사라짐 (로그 보존)

**증상** — 어제 잘 만들어진 대화가 오늘 실행 후 사라졌다.

**원인** — 루프 모드 `bridge.sh`는 **시작하자마자 로그를 비운다** (`: > "$LOG"`).
Stage B의 **Start 버튼과 `reset` 컨트롤 명령도 로그를 truncate**한다(epoch 증가).
게다가 `conversation.jsonl`은 `.gitignore`에 있어 git도 보존해 주지 않는다.

**해결** — 다음 실행 전에 복사해 두거나, 실행마다 다른 로그 파일을 지정한다:

```bash
# 방법 1: 실행 전 백업
cp conversation.jsonl "conversation.$(date +%Y%m%d-%H%M%S).jsonl"

# 방법 2: 실행별 파일 분리
mkdir -p runs
BRIDGE_LOG="runs/url-shortener.jsonl" ./bridge.sh "URL 단축기 설계"
```

`bridge.sh --once`는 로그를 **읽기만** 하고 절대 쓰지 않으므로, 기존 로그를 지우지
않고 한 턴만 더 받아보고 싶을 때 안전하다:

```bash
BRIDGE_LOG=conversation.jsonl ./bridge.sh --once codex   # 응답은 stdout으로만
```

---

## 11. 원본 세션 파일 위치(claude / codex)

**증상** — bridge 로그 말고, 각 CLI가 자체 저장한 원본 세션 기록을 직접 보고 싶다.

**위치와 열람 방법**

- **Claude Code**: `~/.claude/projects/<경로-치환>/<session-id>.jsonl`
  — `<경로-치환>`은 작업 디렉토리 절대 경로의 `/`를 `-`로 바꾼 것. 이 저장소라면:

  ```bash
  ls -t ~/.claude/projects/-Users-wayne-claude-claude-project-codex-claude-cross-platform/*.jsonl | head -3
  ```

  대화 텍스트만 추출 (`.message.content`가 문자열/배열 양쪽 형태를 가진다):

  ```bash
  jq -r 'select(.type=="user" or .type=="assistant")
         | .type + ": " + (.message.content
             | if type=="string" then . else map(.text? // "") | join(" ") end)' \
    ~/.claude/projects/-Users-wayne-claude-claude-project-codex-claude-cross-platform/<session-id>.jsonl
  ```

  (thinking 블록만 있는 assistant 레코드는 빈 줄로 나올 수 있다.)

  주의: 이 스키마는 **내부용이고 버전에 따라 바뀐다(불안정)**. 자동화가 이 형식에
  의존하게 만들지 말 것 — 안정적인 계약은 bridge의 `conversation.jsonl`
  (`{ts, role, text}`)이다.

- **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-<타임스탬프>-<uuid>.jsonl`

  ```bash
  # 가장 최근 세션 파일
  f=$(find ~/.codex/sessions -name 'rollout-*.jsonl' | sort | tail -1); echo "$f"

  # 메시지만 추출 (developer/user/assistant 역할이 섞여 나온다)
  jq -r 'select(.type=="response_item" and .payload.type=="message")
         | .payload.role + ": " + (.payload.content | map(.text? // "") | join(" "))' "$f"
  ```

---

## 12. 테스트 실패 시 읽는 법

**증상** — `bash test/run_all.sh`가 마지막에 `❌ SOME SUITES FAILED`를 출력하고
exit 1로 끝난다.

**원인 파악** — run_all.sh는 스위트마다 `━━ <이름> ━━` 배너를 찍고, **한 스위트가
실패해도 나머지를 끝까지 실행**한다. 따라서 출력 전체를 훑으며 에러 텍스트 바로 위의
배너를 찾으면 어느 스위트인지 알 수 있다 (실패가 여러 개일 수도 있다).

| 배너 | 스위트 파일 | 단독 재실행 |
|---|---|---|
| `━━ bridge: happy path ━━` | `test/run_mock_test.sh` | `bash test/run_mock_test.sh` |
| `━━ bridge: failure + security ━━` | `test/run_error_test.sh` | `bash test/run_error_test.sh` |
| `━━ dashboard: SSE push ━━` | `dashboard/test/sse_test.js` | `node dashboard/test/sse_test.js` |
| `━━ dashboard: interactive ━━` | `dashboard/test/live_test.js` | `node dashboard/test/live_test.js` |
| `━━ dashboard: cancellation ━━` | `dashboard/test/live_cancel_test.js` | `node dashboard/test/live_cancel_test.js` |

**해결**

- 해당 스위트를 단독 재실행해 에러만 분리해서 본다. 모든 스위트는 mock CLI를 쓰므로
  토큰/로그인이 전혀 필요 없다 — 테스트 실패는 실제 계정 문제와 무관하다.
- node 스위트 3개만 돌리려면: `cd dashboard && npm test`.
- 흔한 환경 원인: `jq` 미설치(bash 스위트 + bridge를 스폰하는 interactive/cancellation 스위트), Node 18 미만(node 스위트,
  `dashboard/package.json`의 `engines: node >= 18`), 테스트 포트 4199/4288/4291 점유
  ([7번 섹션](#7-포트-사용-중-eaddrinuse) 방법으로 정리).

---

## 13. live 대시보드 이상 (중복 / 유령 메시지)

**증상** — `http://localhost:4200`에서 메시지가 두 번 보이거나, 이전 대화가 새 대화와
섞여 보이거나, Stop 이후에 답변이 하나 더 붙은 것처럼 보인다.

**원인**

- 클라이언트는 각 레코드의 `_i`(단조 증가, 재사용 안 함)로 중복을 제거하고,
  `epoch`(대화 세대, Start/Reset마다 증가)이 올라가면 이전 DOM을 비운다. 브라우저
  탭이 오래된 상태를 들고 있으면 표시가 어긋날 수 있다.
- **같은 로그에 다른 writer가 쓴 경우** — 예: live-server가 보는 `BRIDGE_LOG`에
  루프 모드 `./bridge.sh`를 같이 돌린 경우. 루프 모드는 파일을 truncate하고
  `_i`/`epoch` 없는 레코드를 쓰므로 dedupe와 epoch 정리가 깨진다. live-server는
  **자신이 유일한 writer**라는 전제로 동작한다 (`bridge.sh --once`는 읽기 전용이라 안전).
- 참고: 정상 동작에서 Stop은 진행 중인 턴을 kill하고 세대 카운터(runGen)가 뒤늦게
  도착한 응답을 버리므로 유령 턴이 기록되지 않는다 — 이는
  `dashboard/test/live_cancel_test.js`가 검증한다.

**해결**

1. **페이지 새로고침** — 접속 시 서버가 로그 전체를 다시 보내고, 클라이언트가 `_i`
   dedupe + epoch 기준으로 화면을 재구성한다.
2. **서버 재시작** — 안전하다. live-server는 부팅 시 기존 로그를 스캔해
   `_i`(최대값+1)와 `epoch`(최대값)을 복원하므로, 재시작해도 id가 재사용되거나
   대화 세대가 꼬이지 않는다:

   ```bash
   lsof -ti tcp:4200 | xargs kill
   cd dashboard && node live-server.js
   ```

3. 그래도 섞여 보이면 로그가 외부 writer로 오염된 경우다 — 새 Start(또는
   `/control`로 보내는 `reset` 명령)로 대화를 비우고, 이후 **루프 모드 bridge.sh와
   live-server에 같은 `BRIDGE_LOG`를 절대 함께 쓰지 않는다.**

---

## 14. `BRIDGE_RESUME` 세션 만료 / 토큰 절감 확인

`BRIDGE_RESUME=1`(옵트인, **루프 모드 전용**)은 매 턴 전체 transcript를 다시 보내는
대신, 각 CLI가 자신의 세션을 resume하게 하고 상대의 최신 메시지(델타)만 전달한다.
기본값은 OFF(`0`)이며, 이때 동작은 예전과 완전히 동일하다.

**증상 A — 실행은 되는데 토큰이 줄지 않는다**

- resume의 실제 이득은 **프롬프트-캐시 할인**이지 청구 입력 토큰 자체의 감소가
  아니다. **실 CLI 검증(2026-07-21)에서 확인됨** — resume 턴은 대부분 캐시에서
  청구된다 (claude `input_tokens=2`/`cache_read=15289`, codex
  `cached_input_tokens=29184`/`38890`).
- claude 캐시는 **1시간**(`ephemeral_1h`) 유효라 `TURN_SLEEP`이 넉넉해도 할인이
  살아있다. 다만 codex는 창이 더 짧으니 `TURN_SLEEP`을 과하게 늘리면 cache miss가
  날 수 있다 — 토큰이 안 줄면 `TURN_SLEEP`을 줄여본다.
- 실측/재확인: `RUN_REAL_CLI=1 tools/verify_resume_real.sh`, 또는 응답 envelope의
  `cache_read_input_tokens` vs `input_tokens`를 직접 비교한다. cache_read 비중이
  낮으면 할인이 없는 것이다.

**증상 B — `resume failed for <speaker> — retrying once without resume` 가 stderr에 보인다**

- 정상 동작이다. 세션이 만료/무효화되면 bridge가 **정확히 1회** 전체 transcript로
  (resume 없이) 재시도해 자동 복구한다(self-heal). 그 재시도가 성공하면 실행은
  계속되고 새 세션 id를 다시 캡처한다.
- 재시도**도** 실패하면 진짜 에러다 — bridge는 실제 진단을 stderr에 남기고
  non-zero로 중단한다(fail-loud, resume가 에러를 숨기지 않는다).

**증상 C — codex resume가 계속 새 세션을 만든다 (절감 안 됨)**

- bridge는 codex `--json` 출력의 `thread.started` 이벤트에서 thread id를 파싱한다.
  codex 버전이 그 이벤트의 필드명을 바꾸면 id 캡처가 실패해 매 턴 새 세션이 생긴다.
  `codex --version` 확인 후, 설치된 버전의 `codex exec --json` 출력 형식이
  `{"type":"thread.started","thread_id":"…"}`인지 점검한다.

**주의**

- resume는 **루프 모드에서만** 동작한다. Stage B(인터랙티브 서버)는 여전히 전체
  transcript를 보낸다(설계상 연기됨).
- resume는 각 CLI의 **private 세션 스토어**(`~/.claude/projects`, `~/.codex/sessions`)에
  기록한다. 그 디렉터리를 지우면 진행 중 resume가 stale이 되어 위 증상 B가 발생한다.
