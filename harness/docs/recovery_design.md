# Worker 수명과 큐 복구 (2026-10-15)

두 번째 개선 묶음입니다. 부모 프로세스가 사라진 것을 worker 종료로 오인한 재실행과, 큐 이동 중 중단으로 작업 파일이 중복되는 문제를 다룹니다.

## Worker 실행 계약

`invoke_assignment_codex.ps1`은 invoke lease를 획득한 뒤 미해결 worker 기록을 검사합니다. 실행 전에 `state/locks/invoke_<assignment>/worker.json`에 고유 invocation ID, 저장소·담당자·assignment, 부모 PID/시작 시각, 실행 명령과 파일 경로를 저장합니다. 프롬프트 본문은 별도 파일로 유지합니다.

실제 CLI는 별도 PowerShell인 `run_assignment_worker.ps1`에서 실행합니다. 이 프로세스는 `worker_<assignment>` lease를 유지하고 자신의 PID/시작 시각을 기록합니다. 출력은 부모를 거치지 않고 run log에 계속 기록합니다. 부모만 종료되어도 이 worker host가 살아 있다면 worker 실행과 로그를 계속할 수 있습니다.

| 기록 상태 | 뜻 | 재실행/복구 |
| --- | --- | --- |
| 기록 없음 | 새 방식으로 실행한 이력 없음 | 기존 invoke lease 및 큐 검사 적용 |
| `starting` | 실행 의도를 저장했고 host 실행 여부가 아직 미확정 | 재실행 차단 |
| `running` | host가 실행을 인수함 | worker lease가 없어져도 자동 재실행 차단 |
| `exited` | host가 CLI 반환과 exit code를 기록함 | lease 해제 후 완료 파일과 대조 가능 |
| `settled` | 부모 또는 복구 명령이 완료 상태와 조정함 | 정상적인 완료/실패 후속 흐름 허용 |

`starting` 저장과 host 시작 사이에 부모가 종료되어도 실행 여부를 추측하지 않습니다. host까지 강제 종료된 경우 OS lease는 풀릴 수 있지만 `running` 기록이 남으므로 중복 실행은 차단됩니다. PID가 사라지거나 재사용됐다는 이유로 기록을 해제하지 않습니다. PID/시작 시각은 진단 정보이며 자동 kill 권한으로 사용하지 않습니다.

정상 실행은 기존 완료 동작 후 `settled`로 바꿉니다. 부모가 중단됐지만 host가 `exited`를 기록했다면 복구 명령으로 완료 파일과 조정할 수 있습니다. 완료 파일이 없다면 exit code 0이어도 검증 통과를 추측하지 않고 `done/__fail.md`로 기록합니다. 이미 완료 파일이 있으면 그 결과를 보존합니다. 미해결 worker는 seed 재시도·이전 pass 채택·자동 feature finalization도 차단하며 resume 보고서에 `worker_unresolved`로 표시됩니다.

현재 실행 중인 worker의 완료 호출에는 `HARNESS_INVOCATION_ID`, `HARNESS_ASSIGNMENT_ID`가 전달됩니다. 다른 invocation이 실행 중인 작업을 완료시키지 못하도록 확인합니다. 이 환경 변수는 로컬 협업 계약이며 로컬 파일/환경 변조에 대한 인증 수단은 아닙니다.

## 큐 전환 journal

claim, complete, stale recovery, seed failure requeue가 담당자별 `.queue` lease를 공유합니다. 기존에 서로 달랐던 claim/complete 잠금을 통합했습니다. 잠금을 잡은 뒤 미완료 journal을 먼저 복구합니다.

`assignments/<owner>/.transitions/<transaction-id>.json`에 source/target의 상대 경로, 원문·결과의 SHA-256, 결과 내용과 상태를 보관합니다. 해시는 UTF-8로 정규화한 텍스트 기준입니다.

1. `pending` intent를 원자적 파일 쓰기로 저장합니다.
2. 목적 파일을 생성합니다.
3. 원본 파일을 삭제합니다.
4. journal을 `committed`로 갱신합니다.

복구는 이 순서를 이어서 수행합니다. 원본만 있으면 목적 파일을 생성하고, 양쪽이 있으면 해시를 확인한 뒤 원본을 삭제하고, 목적 파일만 있으면 journal을 확정합니다. 양쪽 모두 없거나 파일 내용이 달라졌거나 journal이 손상됐다면 중단합니다. 다른 내용을 덮어쓰지 않습니다. 완료 journal은 유지하며 다시 실행하지 않습니다.

중단 후 복구를 여러 번 실행해도 같은 결과가 됩니다. 두 복구 프로세스가 경쟁하면 하나만 queue lease를 획득하며 다른 프로세스는 busy로 실패할 수 있습니다. busy는 해당 작업을 끝낸 뒤 재시도할 수 있습니다. 같은 결과의 complete 재호출은 성공하고 다른 결과로의 재호출은 거부합니다.

`Move-FileWithUpdatedContent`에는 이제 해당 담당자 큐의 원래 lease 객체가 필요합니다. 기존 호출부를 모두 갱신했습니다. raw 파일 이동으로 큐를 변경하는 외부 스크립트는 이 계약을 우회하므로 별도 전환이 필요합니다.

## 복구 명령

설치된 대상 프로젝트 루트에서:

```powershell
# 중단된 파일 이동만 조정
pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent <owner>

# 파일 이동과 해당 worker의 확인된 종료를 함께 조정
pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent <owner> -AssignmentId <id>
```

현재 개발 checkout에는 활성 프로필이 없으므로 위 운영 명령을 그대로 실행하는 대신 fixture 테스트를 사용합니다.

```powershell
pwsh -NoProfile -File scripts/test_harness.ps1
pwsh -NoProfile -File scripts/test_harness_recovery.ps1
```

`repair_assignment_state`는 프로세스를 죽이거나 알 수 없는 실행을 강제로 해제하지 않습니다. `starting/running`, 활성 lease, 손상 또는 범위가 다른 기록은 조정을 거부합니다. 강제 해제 스위치는 제공하지 않습니다. 이런 경우 해당 호스트의 실행 프로세스·worktree·완료 증거를 사람이 확인해야 하며, 기록을 삭제하면 중복 실행 방지 근거를 잃습니다.

`HARNESS_CODEX_PATH`가 설정되면 그 경로를 CLI로 사용하고 없으면 PATH의 `codex`를 찾습니다. 격리 테스트에서는 반드시 fake 스크립트로 지정하고 끝난 뒤 환경 변수를 복원합니다. 지정한 경로를 찾지 못했을 때 실제 Codex로 fallback하지 않습니다.

## 경계와 남은 과제

2026-10-15 추가: 기존 `pass`를 worker 종료 복구로 확정할 때도
[실행 증거](assignment_evidence.md)를 검사합니다. 증거 누락·변경·오래된
snapshot 또는 worker 비정상 종료는 복구 성공으로 처리하지 않습니다.
성공 종료가 확인된 기존 pass의 증거 갱신은 `complete_assignment.ps1 -Revalidate`
명령을 사용하며, 불명확한 worker를 해제하는 기능은 아닙니다.

- 임의의 자식 프로세스 트리를 종료하는 Windows Job Object/POSIX process group 기능은 없습니다. 비정상 host 종료의 불확실성은 실행 차단으로 처리합니다. CLI가 정상 반환 전에 별도로 떼어낸 background 서비스의 수명까지 보장하지 않습니다.
- 네트워크 파일시스템, WSL/Linux, 전원 손실에 따른 디스크 durability는 이번 로컬 검증의 보장 범위가 아닙니다. 테스트는 프로세스 강제 종료와 로컬 파일시스템을 대상으로 합니다.
- journal은 큐 파일 전환을 복구합니다. 최초 assignment와 dispatch packet을 한 번에 생성하는 트랜잭션, 로그 append, Git 통합과 원격 side effect까지 하나로 복구하는 기능은 아닙니다.
- 이전 버전과 새 버전을 같은 큐에서 동시에 운영하면 이전 프로세스가 새 queue lease/journal을 무시합니다. 이전 worker를 종료하고 확인한 뒤 같은 설치의 호출 스크립트를 함께 갱신해야 합니다.
- 이미 생긴 journal 없는 중복 파일은 자동으로 삭제하지 않습니다. `source`와 `target` 충돌을 숨기지 않고 운영자가 확인해야 합니다.
- journal과 worker 기록에는 실행 경로와 작업 내용이 포함될 수 있습니다. 기존 intake 필터를 모든 로그·상태에 대한 비밀값 마스킹으로 해석하지 않습니다.
- 실행 ID별 장기 이력·보존 기간·schema migration 및 불확실한 실행의 검토 후 해제 UX는 후속 과제입니다.
