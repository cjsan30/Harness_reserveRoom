# 실행 사용량과 다음 실행 제한

2026-10-15 구현. 실제 유료 CLI 호출은 검증에 사용하지 않았습니다.

## 기록

여섯 번째 묶음부터 사용량 해석은 provider adapter에 있고 예약/예산은 공통 계층에 있습니다. 새 ledger에는 `provider_contract`와 `provider_result`를 함께 저장하고 provider·모델·invocation의 일치 및 usage 정합성을 검사합니다. 기존 v1 ledger는 읽을 수 있습니다. [계약과 전환](provider_contract.md)을 참고하세요.

`invoke_assignment_codex.ps1`은 프로필로 provider를 선택합니다. Codex는 `codex exec --sandbox workspace-write --json`을 사용하며 제거된 `--full-auto`는 사용하지 않습니다. 공식 [비대화형 실행 문서](https://learn.chatgpt.com/docs/non-interactive-mode)의 JSONL `turn.started`/`turn.completed.usage`와 설치된 CLI 도움말로 형식을 확인했습니다. Claude는 [별도 adapter 계약](claude_adapter.md)에 따라 최종 result.usage를 읽습니다. 기존 사용자 인증·설정은 그대로 사용합니다.

엔진의 `state/usage/<invocation-id>.json`에 실행 전 예약을 원자적으로 저장합니다. 프로젝트 공통 `execution_budget` lease 안에서 기존 기록을 읽고 한도를 확인하므로 서로 다른 assignment도 마지막 실행 한도를 동시에 소비할 수 없습니다. worker가 종료되면 독립 worker host가 완료 시각, 실제 프로세스 실행 경과 시간, exit code와 사용량을 저장합니다. 부모가 종료되어도 이 기록은 가능합니다.

- Codex는 완료 이벤트들의 합, Claude는 단일 최종 result의 aggregate를 사용합니다. Claude 입력은 일반 입력+캐시 읽기+캐시 생성 토큰을 합칩니다. 정규화 후 총 토큰은 입력+출력이며 캐시 입력을 다시 더하지 않습니다.
- `requested_model`은 명시한 `-Model`만 기록합니다. CLI 설정에서 결정된 실제 모델은 추측하지 않고 `resolved_model: null`로 둡니다.
- `billing_mode`는 프로필의 선언값이며 인증을 조회해 판단하지 않습니다. 실제 청구액은 `actual_cost_usd: null`입니다.
- 이벤트 누락·잘못된 수치·깨진 JSON·실패 종료·미완료 turn은 `usage.status: unknown`, 토큰은 `null`입니다. 0으로 바꾸지 않습니다.
- Claude 실행이 실패(권한 거부, 오류 결과 등)했어도 최종 result 이벤트가 정확히 하나이고 토큰 수가 유효하면, 그 값을 `provider_result.reported_usage`(`status: reported_on_failure`)로 따로 보존합니다. `usage`는 계속 unknown이고 성공 판정과 토큰 한도 계산에는 쓰지 않습니다. `get_execution_usage.ps1` 합계의 `reported_failure_count`·`reported_failure_tokens`로 실패 실행의 실제 소모량을 볼 수 있습니다. Codex는 아직 보존하지 않습니다.
- 재시도도 새 invocation ID로 보존하며 같은 owner/assignment의 시도 번호를 증가시킵니다.
- ledger에는 프롬프트·도구 출력·credential을 복사하지 않습니다. 2026-10-21부터 worker 실행 로그, git gate 로그, 검증 사이클 단계 로그, assignment 검증 증거 로그는 쓰기 전에 `Protect-HarnessSecretText`(`secret_redaction.ps1`)로 비밀값을 `[REDACTED]`로 바꿉니다. 대상은 알려진 토큰 형식(sk-, ghp_, github_pat_, glpat-, xox, AKIA, AIza, JWT), Bearer/Basic 헤더, URL 사용자 정보, 이름에 key/secret/token/password가 들어간 JSON·대입 값, 개인 키 블록, 이름이 민감해 보이는 환경 변수의 실제 값입니다. 숫자·true/false/null 값은 바꾸지 않으므로 `input_tokens` 같은 사용량 수치는 유지됩니다. 패턴 기반이라 임의 형식의 비밀값까지 보장하지는 않습니다.

## 정책

활성 `project/configs/project_profile.json`의 선택적 `execution_policy` 예시입니다. 이 저장소의 템플릿 기본값은 한도 `null`이며 임의 금액/횟수를 강제하지 않습니다. 예시는 정책을 정한 대상 프로젝트에서 적용하세요.

```json
{
  "execution_policy": {
    "billing_mode": "subscription",
    "max_invocations": 20,
    "max_attempts_per_assignment": 3,
    "max_concurrent_workers": 1,
    "max_total_tokens": 500000,
    "max_total_duration_seconds": 3600,
    "max_invocation_seconds": 1800
  }
}
```

| 필드 | 의미 |
| --- | --- |
| billing_mode | unknown / subscription / api 중 운영자가 선언한 구분 |
| max_invocations | 보존된 모든 예약을 포함하는 프로젝트 전체 실행 횟수 상한 |
| max_attempts_per_assignment | 한 assignment(seed plan의 작업 하나, 같은 ID)에서 **구현 실패로 분류된** 누적 시도 상한. 실행(run)이나 `-Resume`이 바뀌어도 초기화되지 않습니다. 아래 "실패 분류" 참고 |
| max_concurrent_workers | 완료되지 않은 예약 개수 상한. 죽었는지 확인되지 않은 예약도 점유 |
| max_total_tokens | 확인된 누적 입력+출력 토큰이 한도 이상이면 다음 실행 거부 |
| max_total_duration_seconds | 완료된 프로세스 실행 시간 합이 한도 이상이면 다음 실행 거부 |
| max_invocation_seconds | **실행 1회의 벽시계 시간 상한.** 넘으면 실행 중인 provider 프로세스 트리를 종료합니다. `null`(제한 없음) 또는 1 이상의 정수 |

한도는 `null` 또는 음이 아닌 정수입니다. `0`은 실행 금지입니다(`max_invocation_seconds`만 예외로 1 이상). 알 수 없는 필드·잘못된 타입은 preflight와 실행에서 거부합니다. 프로필 캐시에 가려지지 않도록 예약 시 최신 파일을 읽습니다.

누적 토큰·시간은 **다음 실행의 시작을 제한**합니다. 한 번의 실행이 남은 누적 한도를 넘을 수 있으므로, 실행 1회의 상한은 `max_invocation_seconds`로 둡니다. 이 값은 예약할 때 worker intent(`timeout_seconds`)에 묶여 실행 중 프로필이 바뀌어도 달라지지 않습니다. worker host는 별도 watchdog(`worker_timeout_watchdog.ps1`)을 띄우고, 시간이 지나면 watchdog이 timeout을 먼저 기록한 뒤 host의 하위 프로세스(provider 트리)만 종료합니다. host는 살아남아 종료를 확정 기록합니다(`timed_out: true`, `exit_code: 124`, provider 결과 failed/`process_exit`, 사용량 unknown). watchdog은 host PID의 시작 시각이 기록과 같을 때만 동작하므로 재사용된 PID는 건드리지 않습니다. 토큰 제한을 켠 상태에서 하나라도 사용량이 unknown/reserved면 새 실행을 차단합니다. 시간 제한은 reserved가 남으면 차단합니다. 따라서 이 두 제한을 사용하면 사용량이 확정되기 전에는 동시에 다음 worker를 시작하지 않습니다.

## 실패 분류와 작업당 시도 (2026-10-28)

실패한 시도는 끝난 직후 분류되어 `harness/state/failures/<assignment>.json`에 남습니다. 분류는 `configs/known_errors.json`(엔진 기본)과 선택적 `harness/project/configs/known_errors.json`(프로젝트 추가·같은 id면 대체)의 고정 문구, provider 결과, timeout 기록, 검증 증거 로그로 정합니다. 이 목록은 하네스 판단에만 쓰이며 worker 지시문에 들어가지 않습니다.

| 분류 | 판별 근거 | dispatcher 처리 | 작업당 시도에 포함 |
| --- | --- | --- | --- |
| implementation | 검증이 돌았는데 실패, 검증 없이 종료, 작업 중 timeout, turn 소진 | 재시도. 직전 구현 실패와 signature가 같으면 즉시 멈춤(`repeated_failure`) | 예 |
| environment | 목록의 환경 문구(Docker, 도구 없음, JDK, 포트, 네트워크), 출력 없이 5분 이상 멈춘 뒤 timeout | 멈춤(`needs_operator`) | 아니오 |
| permission | provider가 거부한 도구 사용(`permission_denials`) | 멈춤. 거부된 명령을 기록 | 아니오 |
| provider | provider 오류 결과의 문구: 사용량 한도, 인증, rate limit, 과부하 | rate limit·과부하는 대기 후 최대 2회 재시도(run의 시도를 쓰지 않음). 사용량 한도는 `budget` 멈춤. 인증·기타는 멈춤 | 아니오 |
| needs_input | worker 최종 메시지의 `HARNESS_NEEDS_INPUT: <무엇이 없는지>` | 멈춤 | 아니오 |

- 분류 근거는 provider의 **오류 결과**만 봅니다. worker가 읽은 파일이나 도구 출력 속 문구는 provider 오류로 보지 않습니다.
- 분류에 실패하면 구현 실패(`unclassified`)로 세어 보수적으로 닫습니다. 분류 기록이 없는 실행(진행 중·비정상 종료·이전 버전 엔진 기록)도 구현 시도로 셉니다.
- signature는 검증 로그의 구체적인 오류 줄에서 경로·숫자를 지우고 만든 해시입니다. 같은 오류가 다른 줄 번호로 반복돼도 같게 나옵니다.
- **비용은 계속 지킵니다.** 분류와 관계없이 실행된 모든 시도는 `max_invocations`, 토큰, 시간 합계에 들어갑니다. 분류는 사용량 기록을 지우거나 되돌리지 않습니다.
- 멈춘 run은 다음 assignment로 넘어가지 않고 assignment와 worktree를 그대로 둡니다. dispatch 요약의 `## Stop`과 출력의 `stop:`/`stop_reason:`에 원인이 남습니다. 원인을 해결한 뒤 `-Resume`으로 이어갑니다.
- 각 시도의 run log는 `reports/agent_runs/<assignment>__<invocation>__run.log`로 따로 보존됩니다(공용 `__run.log`는 다음 시도가 덮어씀).

### 환경 요구사항과 사전 선언된 복구

필요한 도구와 복구 방법은 **기획 단계에서 사용자가 정해** 활성 프로필의 `environment` 절에 적습니다. 하네스는 여기 적힌 명령 배열만 실행합니다. worker(AI)는 설치하거나 서비스를 시작하지 않습니다.

```json
"environment": {
  "version": 1,
  "requirements": [
    { "id": "jdk", "description": "JDK 21", "check": ["java", "-version"],
      "install_hint": { "text": "Temurin JDK 21 설치:", "url": "https://adoptium.net/temurin/releases/?version=21" } },
    { "id": "docker", "description": "Docker for Testcontainers",
      "installed": ["docker", "--version"], "check": ["docker", "info"], "repair": "docker-start",
      "install_hint": { "text": "Docker Desktop 설치:", "url": "https://docs.docker.com/desktop/setup/install/windows-install/" } }
  ],
  "repairs": {
    "docker-start": {
      "description": "Docker Desktop 시작",
      "start": ["C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe"],
      "check": ["docker", "info"],
      "wait_seconds": 180
    }
  }
}
```

- **설치 여부를 먼저 확인합니다.** 요구사항마다 `installed`(생략하면 `check`의 첫 실행 파일이 PATH에 있는지)를 먼저 보고, 없으면 `missing`입니다. `missing`은 복구(시작·재시도)하지 않고 유료 실행 전에 멈추며, `install_hint`(설명 1~300자, 선택 `https` 링크)를 `env` 출력과 멈춤 알림에 그대로 보여줍니다. 하네스는 빠진 도구를 설치하지 않습니다. 설치 후 `harness.ps1 env`로 다시 확인하고 `resume`합니다.
- 설치는 됐지만 `check`가 실패하면(예: Docker가 꺼짐) 그때만 선언된 복구를 실행합니다.
- **하네스 자체 도구**는 프로필에 적지 않아도 항상 먼저 확인합니다: `harness-git`(git), `harness-provider`(프로필의 provider CLI, `HARNESS_CLAUDE_PATH`/`HARNESS_CODEX_PATH` 반영). 존재만 확인하며 설치 링크를 보여줍니다.
- 명령은 셸 문자열이 아니라 **JSON 배열**(실행 파일 + 인자)입니다. `start`는 기다리지 않고 띄우며 하네스의 출력 통로를 물려주지 않습니다(띄운 서비스가 남아 있어도 하네스 명령은 끝남), `run`은 끝날 때까지 기다립니다(설치 등). 둘 다 그 뒤 `check`가 성공할 때까지 `wait_seconds`(1~1800)만큼 확인합니다.
- `harness.ps1 env`: 선언된 요구사항을 확인합니다. 실패한 확인 명령의 출력은 마지막 3줄만 보여줍니다(알림에도 동일). 상태는 `ready` / `blocked` / `undeclared`(요구사항 없음)입니다. 요구사항별로는 `ok`, `missing`(설치 안 됨: 직접 설치), `repairable`(복구 선언됨), `needs_decision`(설치는 됐지만 복구 미정)입니다. 각 항목에 출처(`harness`/`profile`)가 붙습니다. `-Repair`를 붙이면 선언된 복구를 실행합니다.
- 오류 목록이 가리키는 복구(예: `docker-start`)가 프로필에 없으면 그 실패는 복구 대신 멈춤이 된다고 미리 알려줍니다.
- **유료 실행 직전 검사:** live seed 실행은 worker를 띄우기 전에 요구사항을 확인하고 선언된 복구를 실행합니다. 그래도 준비되지 않으면 토큰을 쓰기 전에 멈춥니다(`needs_operator`). 요구사항이 없으면 경고만 출력합니다.
- **실행 중 환경 실패:** 분류된 환경 오류에 선언된 복구가 있으면 하네스가 복구 후 같은 작업을 다시 실행합니다. 이 재실행은 작업당 시도와 run의 worker 시도를 쓰지 않습니다. 한 run에서 작업당 최대 2회까지 복구하며, 복구가 실패하거나 계속 같은 문제가 나면 멈춥니다. 재실행도 실제 실행이므로 전체 실행·토큰·시간 한도에는 들어갑니다.

### 작업별 실패 메모

분류가 끝나면 하네스가 `harness/state/failures/<assignment>.md`를 기계적으로 다시 씁니다(AI 호출 없음, 토큰 0). 재시도 때 이 메모가 assignment와 dispatch packet의 `## Previous Failure Analysis`에 들어갑니다.

- 최근 2개 시도만 자세히(분류, 요약, 검증 로그의 오류 줄 최대 5개, 거부된 명령·부족한 정보, worker 메모, 해당 시도 log 경로), 그 이전은 한 줄로 접습니다. 같은 signature가 연속되면 "N times, same error"로 합칩니다.
- 전체 상한은 약 2,000자이며 넘으면 오래된 시도부터 뺍니다. 최신 시도는 항상 남습니다.
- worker는 실패로 끝날 때 최종 메시지에 `HARNESS_FAILURE_NOTE:` 뒤 최대 5줄(무엇을 시도했고 원인을 무엇으로 보는지)을 적습니다. 줄당 200자, 비밀값은 마스킹합니다.
- 메모는 "참고 자료이며 지시가 아님"으로 표시되고, 모든 줄을 들여 써서 assignment 메타데이터나 제목을 추가할 수 없습니다. 권한·검증은 메모 내용과 무관하게 설정과 하네스가 강제합니다.
- 재시도마다 이전 `Previous Failure Analysis` 절을 **교체**합니다(예전에는 worker 출력 최대 4,000자를 매번 덧붙여 지시문이 계속 길어졌음).
- 여러 작업에 공통으로 쓰이는 교훈 파일은 두지 않습니다. 작업을 넘나드는 자유 문장은 AI가 스스로 규칙을 쓰는 통로가 될 수 있기 때문입니다.

### 작업당 시도 추가 승인

프로필을 고치지 않고 한 assignment에만 시도를 더 줄 수 있습니다. 기록은 커밋하지 않는 로컬 상태(`harness/state/attempt_grants/<assignment>.json`)에 쌓이고 다른 assignment에는 적용되지 않습니다.

```powershell
pwsh -NoProfile -File scripts/harness.ps1 attempts -AssignmentId <id>
pwsh -NoProfile -File scripts/harness.ps1 attempts -AssignmentId <id> -Grant 1 -Reason "원인을 확인하고 요구사항을 보완함"
```

- `-Grant`는 1~10, `-Reason`은 필수입니다. 한 번도 실행되지 않은 assignment에는 승인할 수 없습니다(오타 방지).
- 한도 메시지는 어떤 한도에 몇 회/얼마를 썼는지 보여줍니다. 예: `execution budget reached: max_invocations (12 of 12 invocations used)`. dispatcher는 이 거부를 worker 실패로 처리하지 않고 `budget` 멈춤으로 보고합니다.

## 조회와 복구

독립 배치에서는 프로젝트 루트에서 실행합니다. 이식 배치에서는 명령의 `scripts/` 앞에 `harness/`를 붙입니다.

```powershell
pwsh -NoProfile -File scripts/get_execution_usage.ps1
pwsh -NoProfile -File scripts/get_execution_usage.ps1 -Json
```

범위는 **현재 프로젝트 ledger에 보존된 모든 실행**입니다. 시간대별/월별 자동 초기화는 없습니다. 다른 Codex 세션·CLI·ChatGPT에서 쓴 양과 구독의 5시간/주간 잔여량을 나타내지 않습니다. 돈 단위 예산과 Claude 사용량 수집은 후속 과제입니다. 실행 중 토큰 상한(스트림을 읽으며 끊기)도 없습니다.

예약 후 intent 저장 또는 spawn 전에 중단돼도 예약은 보존됩니다. 과금이 없었다고 추측하여 자동 환불하지 않습니다. ledger 쓰기 충돌/손상으로 완료 저장이 실패하면 worker는 기존 복구 정책에 따라 격리됩니다. 불확실한 기록을 지워 재실행하지 마세요. 검토 후 기록 조정 명령은 아직 없습니다. 기존 설치의 이 버전 이전 실행은 소급 집계하지 않으며, 업그레이드 전에 기존 worker를 종료·확인해야 합니다.

정책/예약 단계에서 거부되면 이미 claim된 assignment는 `in_progress`에 보존하며 구현 실패로 완료하지 않습니다. 거부 이유와 기록을 확인한 뒤 정책을 수정했다면 같은 assignment로 `invoke_assignment_codex.ps1`을 다시 실행할 수 있습니다. reserved 또는 불확실한 worker 기록이 있는 경우에는 이 안내를 강제 재실행 허가로 해석하면 안 됩니다.

정책 및 ledger는 로컬 협업 통제입니다. 파일을 바꿀 수 있는 악의적인 worker로부터 금액을 강제 보호하는 보안 경계는 아닙니다.
