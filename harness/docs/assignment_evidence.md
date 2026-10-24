# 실행 증거에 기반한 작업 성공 판정

2026-10-15 구현. `complete_assignment.ps1 -Result pass`는 assignment의 `validation` 명령을 실제로 실행한 뒤 증거가 유효할 때만 큐를 `done`으로 이동합니다. AI의 성공 설명이나 `result: pass` 문자열만으로 성공을 인정하지 않습니다.

## 성공의 의미와 증거

| 구분 | 이번 구현의 판정 |
| --- | --- |
| 파일·설정 생성 | 존재나 문자열 검사는 해당 검사에서 확인한 범위만 증명 |
| 설정된 검증 명령 실행 | exit code 0, 전후 동일한 코드 snapshot, 로그·assignment·worker 연결을 확인해야 성공 |
| 제품의 요구사항 충족 | 명령에 포함된 assertion 범위에 달림. Harness가 독립적으로 제품 동작을 확인했다고 주장하지 않음 |

증거 JSON에는 `claim: configured_command_execution`, `product_behavior: not_independently_verified`를 기록합니다. 빈 명령, 단순 출력/no-op, 단순 `--version`/`--help`, 알려진 실패 무시 패턴을 거부하지만 임의의 명령이 유의미한 테스트인지 완전히 판별할 수는 없습니다. 검증 스크립트에는 실제 입력·출력·동작 assertion이 필요합니다.

각 실행은 엔진의 `state/validation/<GUID>.json`과 `.log`를 남깁니다. 독립 배치는 `state/validation`, 이식 배치는 `harness/state/validation`이며 Git ignore 대상입니다. JSON에는 다음을 연결합니다.

- 저장소 절대 경로, owner, assignment ID, worker invocation ID와 실행 worktree
- 검증 명령, UTC 시작·종료 시각, 소요 시간, 종료 코드, running/pass/fail/error
- Git HEAD·branch·index tree 및 소스 파일 경로/내용 집합의 SHA-256
- 로그 경로·SHA-256, 입력 assignment와 완료 assignment의 hash

완료 파일의 `validation_evidence`가 해당 JSON을 참조합니다. 완료 반복 호출, worker 종료 처리, 복구, seed 재개·재시도·자동 승격 및 상태 조회가 증거를 다시 검사합니다. 활성 worker는 자신의 invocation 안에서만 완료할 수 있습니다. 상위 실행자는 worker의 exit 0까지 확인한 뒤 성공으로 처리합니다. worker가 완료 후 코드를 수정하거나 비정상 종료하면 성공으로 인정하지 않습니다.

## 검증 명령 작성과 실행

assignment에는 `assignment_id`, `status`, `result`, `validation`을 각각 한 번만 기록합니다. `validation`은 담당자 기본 명령으로 조용히 대체하지 않습니다. Git baseline과 일반 branch가 필요하며 detached HEAD, 충돌한 index는 증거 생성을 실패시킵니다.

```text
- validation: pwsh -NoProfile -File scripts/verify_task.ps1
```

위 형태의 `pwsh` 또는 `powershell[.exe] -File`은 Harness가 선택한 PowerShell 런타임으로 실행하며 literal 작업 디렉터리와 terminating error 처리를 지정합니다. 스크립트 경로는 해당 workspace 내부여야 합니다. 지원되는 앞 옵션은 `-NoProfile`, `-ExecutionPolicy <value>`입니다. 다른 명령은 기존 OS shell과 종료 코드 계약을 사용합니다. `--version`으로 런타임만 확인하는 명령은 작업 검증으로 사용할 수 없습니다.

PowerShell 5.1에서는 대괄호 경로 아래의 상대 `-LiteralPath`가 잘못 해석될 수 있습니다. 검증 스크립트는 `$PSScriptRoot`와 `Join-Path`로 입력의 절대 경로를 만들고, 실패한 assertion에서 예외 또는 0이 아닌 exit code를 반환해야 합니다. 스크립트가 자체적으로 오류를 삼키거나 오류 정책을 덮어쓰는 것까지 탐지하지는 않습니다.

검증 중 tracked 파일과 비무시 untracked 파일을 변경하면 완료를 거부합니다. 생성되는 테스트 산출물·캐시·로그는 대상의 ignore 정책에 포함하세요. 엔진 `reports/`, `state/`, `assignments/`는 snapshot에서 제외합니다. 나머지 tracked 파일은 ignore 규칙과 관계없이 포함하며, ignored untracked 파일은 포함하지 않습니다. Git 파일 목록은 NUL 구분 UTF-8로 읽어 한글 파일명도 포함합니다. submodule과 링크 파일은 지원하지 않으며 확인된 경우 거부합니다.

## 완료·재검증·전환

설정된 대상 저장소 루트에서 실행합니다. 독립 배치에서는 아래 `harness/` 접두사를 제거합니다.

```powershell
# 진행 중인 작업: 실제 검증 성공 뒤 완료
pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent tester -AssignmentId task-id -Result pass

# 기존 pass의 누락되거나 오래된 증거: 명시적으로 다시 실행
pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent tester -AssignmentId task-id -Result pass -Revalidate
```

일반 반복 완료는 기존 증거가 유효할 때만 성공하며 검증을 자동으로 재실행하지 않습니다. `-Revalidate`는 수동 assignment 또는 성공 종료가 확인된 worker에만 허용됩니다. 기존 JSON·로그를 보존하고 새 ID로 다시 검증합니다. 실패하면 기존 완료 파일을 성공으로 갱신하지 않으며 진행 중 작업의 검증 실패는 `in_progress`에 남습니다. invoke 경로는 기존 정책에 따라 이후 실패 완료를 기록할 수 있습니다.

구형 `pass`에 증거가 없으면 `get_seed_handoff_resume.ps1`은 `validation_unverified`/`needs_recovery`, `get_harness_status.ps1`은 `done_unverified`를 보고하고 성공 수에서 제외합니다. 기록을 삭제하거나 `pass`를 직접 적어 우회하지 말고 명령·소스·worker 종료 상태를 확인한 후 재검증하세요. 비정상 worker exit는 `-Revalidate`로 덮어쓸 수 없습니다.

자동 seed 승격은 증거 확인 후 기존 feature gate·stage·commit을 수행합니다. index/HEAD가 바뀌므로 최종 commit에서 assignment 검증을 다시 실행합니다. integration gate 뒤에도 증거를 확인한 다음 기존 승인 절차를 따릅니다. `main` 승인 정책은 유지됩니다.

## 운영 경계

Provider 계약이 있는 worker의 성공 종료에는 유효한 정규화 결과가 필요합니다. exit 0이어도 provider가 실패 이벤트를 보고하면 pass·복구·재검증을 거부합니다. provider 실행 `succeeded`만으로 제품 동작 또는 assignment 성공을 판정하지 않습니다. [Provider 계약](provider_contract.md)을 참고하세요.

- 검증은 owner queue lease 안에서 실행하므로 같은 owner의 큐 변경은 대기/거부될 수 있습니다. timeout이나 process-tree 강제 종료는 아직 없습니다.
- 코드 snapshot은 검사 시점의 정합성을 확인합니다. 외부 프로세스의 동시 변경을 파일 잠금으로 막지는 않으며 검증 도중 바뀌었다 복원된 내용까지 감지한다고 보장하지 않습니다.
- ignored dependency·환경 변수·외부 서비스·실행 도구 자체는 소스 hash의 범위가 아닙니다. hermetic build 증명이나 artifact 서명도 제공하지 않습니다.
- 로컬 파일을 쓰는 주체가 증거와 소스를 모두 위조하는 공격에 대한 보안 경계는 아닙니다.
- 검증은 재실행됩니다. 외부 발송·결제 같은 side effect 없이 반복 가능한 테스트를 설정하세요. 모든 로그의 secret 마스킹과 자동 보존 기간은 미구현입니다.
- 상태 폴더 이동·worktree 삭제·로그 제거·소스/HEAD/index 변경 후에는 이전 증거가 유효하지 않을 수 있습니다. 저장소 이동은 기존 승인 재발급 정책에도 해당합니다.
- 로컬 테스트는 fake worker와 Git fixture입니다. 실제 AI, 원격 merge, WSL/Linux 결과를 뜻하지 않습니다. 검증 기록을 참고하세요.
