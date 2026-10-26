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
| max_attempts_per_assignment | 같은 owner/assignment의 누적 실행 시도 상한. seed의 기존 반복 제한에도 추가 적용 |
| max_concurrent_workers | 완료되지 않은 예약 개수 상한. 죽었는지 확인되지 않은 예약도 점유 |
| max_total_tokens | 확인된 누적 입력+출력 토큰이 한도 이상이면 다음 실행 거부 |
| max_total_duration_seconds | 완료된 프로세스 실행 시간 합이 한도 이상이면 다음 실행 거부 |
| max_invocation_seconds | **실행 1회의 벽시계 시간 상한.** 넘으면 실행 중인 provider 프로세스 트리를 종료합니다. `null`(제한 없음) 또는 1 이상의 정수 |

한도는 `null` 또는 음이 아닌 정수입니다. `0`은 실행 금지입니다(`max_invocation_seconds`만 예외로 1 이상). 알 수 없는 필드·잘못된 타입은 preflight와 실행에서 거부합니다. 프로필 캐시에 가려지지 않도록 예약 시 최신 파일을 읽습니다.

누적 토큰·시간은 **다음 실행의 시작을 제한**합니다. 한 번의 실행이 남은 누적 한도를 넘을 수 있으므로, 실행 1회의 상한은 `max_invocation_seconds`로 둡니다. 이 값은 예약할 때 worker intent(`timeout_seconds`)에 묶여 실행 중 프로필이 바뀌어도 달라지지 않습니다. worker host는 별도 watchdog(`worker_timeout_watchdog.ps1`)을 띄우고, 시간이 지나면 watchdog이 timeout을 먼저 기록한 뒤 host의 하위 프로세스(provider 트리)만 종료합니다. host는 살아남아 종료를 확정 기록합니다(`timed_out: true`, `exit_code: 124`, provider 결과 failed/`process_exit`, 사용량 unknown). watchdog은 host PID의 시작 시각이 기록과 같을 때만 동작하므로 재사용된 PID는 건드리지 않습니다. 토큰 제한을 켠 상태에서 하나라도 사용량이 unknown/reserved면 새 실행을 차단합니다. 시간 제한은 reserved가 남으면 차단합니다. 따라서 이 두 제한을 사용하면 사용량이 확정되기 전에는 동시에 다음 worker를 시작하지 않습니다.

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
