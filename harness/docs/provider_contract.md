# Provider 실행·결과·사용량 계약

2026-10-15 여섯 번째 구현. Codex 실행 파일 선택·인수 구성·버전 조회·JSONL 해석을 `provider_codex.ps1`로 옮겼습니다. `provider_contract.ps1`은 버전이 있는 요청과 결과, 지원 provider 선택과 호환성 처리를 담당합니다. worker host와 예산 ledger는 정규화된 결과를 소비합니다.

일곱 번째 구현부터 **Codex와 Claude adapter**를 제공합니다. [Claude 실행·권한·usage 계약](claude_adapter.md)을 함께 읽으세요. 미지원 이름은 거부하며 Harness가 자동 provider 전환이나 유료 fallback을 수행하지 않습니다. 테스트에서는 명시적으로 지정한 로컬 fake 실행기만 사용합니다. API 키 생성·인증 변경·구독/요금 조회는 하지 않습니다.

## 구성과 실행 요청

대상 프로필의 선택적 구성입니다. 개발 저장소에는 활성 프로필을 만들지 않았습니다.

```json
{
  "worker_provider": { "version": 1, "name": "codex" }
}
```

필드가 없던 구형 프로필은 기존 Codex 동작을 유지합니다. 명시적인 null, 알 수 없는 이름·버전·필드는 preflight와 invoke에서 거부합니다. 문자열 `"1"`도 버전으로 허용하지 않습니다. 사용자 설정에서 adapter 파일 경로나 함수 이름을 받아 실행하지 않습니다.

Claude 선택은 위 name을 `claude`로 지정합니다. 기본 템플릿은 계속 Codex이며 Claude 실행 파일은 `HARNESS_CLAUDE_PATH` 또는 PATH에서 선택합니다.

`New-HarnessProviderLaunch`는 다음을 반환합니다.

| 필드 | 계약 |
| --- | --- |
| contract | version=1, provider, requested_model(명시하지 않으면 null) |
| executable / arguments | adapter가 만든 실행 파일과 분리된 인수 목록 |
| input_mode / output_mode | 현재 stdin / jsonl |

기존 `invoke_assignment_codex.ps1`과 seed/CLI 진입점은 유지합니다. invoke가 요청을 만들고, 큐·worktree·잠금·validation prompt를 준비합니다. `New-AssignmentWorkerIntent`는 요청의 provider 계약과 실행 파일·인수·prompt/log/workspace 경로를 worker intent에 저장한 뒤 기존 usage 예약과 host 실행 절차를 사용합니다. 일반 lifecycle 테스트용 직접 intent 생성은 생략된 provider 메타데이터를 기존 Codex 계약으로 정규화합니다.

`HARNESS_CODEX_PATH`로 지정한 파일을 찾지 못하면 PATH의 다른 Codex로 대체하지 않습니다. 없으면 기존처럼 PATH의 `codex`를 선택합니다. 기존 `--sandbox workspace-write --json` 등의 옵션을 유지하며 sandbox 우회 옵션을 추가하지 않았습니다. 인수에 모델 이름을 추가하는 로직은 adapter에만 있습니다.

## 결과 계약 v1

host는 실제 프로세스 반환 후 로그를 해석하여 `provider_result`를 만듭니다. worker 기록과 usage ledger 양쪽에 같은 invocation 결과를 저장합니다.

| 필드 | 의미 |
| --- | --- |
| version / provider / invocation_id | 결과 버전, 실행 요청의 provider, 실행 시도 ID |
| exit_code | 실제 프로세스 종료 코드 |
| execution_status | succeeded 또는 failed. 비정상 exit 또는 명시적 provider 실패 이벤트면 failed |
| response_status | completed / failed / unknown. 로그에서 확인한 응답 진행 상태 |
| error_kind | none / process_exit / provider_error / provider_protocol. 오류 원문은 복사하지 않음 |
| requested_model / resolved_model | 요청 모델과 실제 모델. 현재 실제 모델은 null이며 추정하지 않음 |
| usage | 아래의 정규화된 사용량 |

프로세스 exit 0이더라도 `turn.failed` 또는 `error` 이벤트가 있으면 실행 실패입니다. 이 경우 작업자가 이미 pass 파일을 만들었어도 invoke·완료 증거 검사·복구·재검증에서 성공으로 인정하지 않습니다. worker는 확인된 `exited` 상태와 실패 결과를 보존하며 성공으로 settle하지 않습니다.

Codex의 기존 호환 경로는 일반 텍스트만 있는 exit 0을 프로세스 실행 `succeeded`, 응답 `unknown`, 사용량 `unknown`으로 둡니다. Claude는 유효한 최종 result가 없으면 `provider_protocol` 실패입니다. **provider 실행 성공만으로 assignment를 완료하지 않으며**, 기존 [실행 증거](assignment_evidence.md)가 유효해야 합니다. 알려지지 않은 JSON 이벤트는 응답 성공 근거가 아닙니다. 깨진 JSON/미완료 순서는 usage를 unknown으로 만들며, 명시적 실패 이벤트가 있으면 다른 성공 이벤트보다 우선합니다.

## 사용량·예산 계약

`usage.status`는 known/unknown입니다. known일 때 input_tokens, cached_input_tokens, output_tokens는 음이 아닌 정수이며 cached_input_tokens는 input_tokens 이하입니다. unknown일 때 세 값은 null입니다. 현재 Codex adapter는 완료 turn을 합산하고 캐시 입력은 입력 토큰에 이미 포함된 부분으로 취급합니다.

ledger 예약은 실행 요청의 provider·requested_model을 고정합니다. 완료 시 owner·assignment·invocation에 더해 provider·모델 일치도 검사합니다. 저장된 usage와 provider_result의 usage가 다르면 다음 조회/실행에서 거부합니다. 결과 버전·ID·종료 코드·상태·사용량 타입 불일치도 거부합니다.

미확인 사용량은 0이 아니며 기존 token/time/attempt/concurrency 제한을 그대로 적용합니다. billing_mode는 운영자의 선언, 실제 청구액과 resolved_model은 null입니다. 새 요청이 다른 provider라는 이유로 기존 예약이나 예산을 초기화하지 않습니다. 현재 집계 범위는 [사용량 문서](execution_usage.md)와 같습니다.

## 호환성과 복구

- 기존 프로필에 worker_provider가 없으면 Codex입니다. 명시한 잘못된 구성은 기본값으로 치환하지 않습니다.
- provider_contract가 없는 구형 worker는 과거 Codex 전용 기록으로 해석합니다. 과거 `-m` 인수 읽기도 adapter의 호환 함수에만 남아 있습니다.
- 구형 usage ledger v1은 유지하며 새 예약에는 provider_contract/provider_result 필드를 추가합니다. 구형 예약을 완료하면 계약 필드도 함께 기록합니다. 기록이 없는 과거 실행을 소급 생성하지 않습니다.
- 새 계약이 있는 worker의 성공 종료에는 유효한 provider_result가 필요합니다. 기록을 지워 legacy 경로로 바꾸는 것은 지원되는 복구 절차가 아닙니다.
- host가 ledger 완료 기록 후 worker 상태 저장 전에 중단되면 기존 정책처럼 격리합니다. 불확실한 예약을 환불하거나 worker를 자동 재실행하지 않습니다.
- readiness 보고서는 `provider`, `provider_contract_version`, `provider_path`, `provider_version`을 사용합니다. 이전 `codex_path`/`codex_version` 필드에 의존한 외부 파서는 변경이 필요합니다. 최종 summary에는 provider 실행·응답 상태와 오류 분류를 기록합니다.
- 완료 증거 검사에서 중단되면 최종 summary가 생성되지 않을 수 있습니다. 이 경우 CLI 오류와 보존된 worker/usage의 provider_result를 확인하세요.
- 기존 실행을 종료·확인한 뒤 common/adapter/host/invoke/usage/evidence 스크립트를 함께 교체하세요. 구버전은 새 provider 실패 의미를 알지 못합니다.

## 보장 범위와 후속 작업

로컬 기록은 협업 통제이며 코드·상태 파일을 모두 수정할 수 있는 공격자에 대한 보안 경계는 아닙니다. raw 실행 로그의 모든 secret 마스킹, provider별 인증·rate limit 재시도, 실제 모델 판정·금액 산정, 실행 중 timeout은 남아 있습니다. 결과의 오류 분류는 일반 process/provider/protocol failure 수준이며 인증 실패나 quota 초과를 근거 없이 단정하지 않습니다.

추가 provider는 명시적인 registry 분기, 실행 인수/권한 정책, 응답·usage 정규화, 계약·fixture 검증을 추가해야 합니다. JSON schema 파일이나 임의 plugin loader를 제공하는 것은 아닙니다. 실제 AI와 원격 서비스 검증은 별도입니다.

```powershell
pwsh -NoProfile -File scripts/test_provider_contract.ps1
pwsh -NoProfile -File scripts/harness.ps1 usage -Json
```

이식 배치는 `harness/scripts/`를 사용합니다. 테스트 범주와 결과는 [provider 검증 기록](archive/verification_provider_2026-10-15.md)에 있습니다.
