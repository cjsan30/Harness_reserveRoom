# Harness 개선 진행표

## 추가: 사용자가 요청한 조회 현황판

18개 과제와 별도로 `dashboard` 조회 UI를 구현했습니다. 17번의 운영 상태 통합을 부분 완료합니다.
작업/worker/증거/사용량/승인/최근 사이클을 로컬에서 조회하며 실행·승인 동작은 제공하지 않습니다.
분모는 보존된 등록 작업입니다. 계획 전체·실시간 단계·대규모 증분 수집은 남아 있습니다.
[계약](dashboard.md), [검증](archive/verification_dashboard_2026-10-15.md). 아래 표의 과거 검증 숫자는 당시 이력입니다.

2026-10-15 로컬 현황판 구현 이후 기준입니다. 배경은 [현재 상태](current_state.md)와 [후속 대화](archive/conversation_history_2026-10-15.md), 최신 테스트 근거는 [현황판 검증](archive/verification_dashboard_2026-10-15.md)에 있습니다. 이전 명령/OS 검증은 [플랫폼별 기록](archive/verification_platforms_2026-10-15.md)에 보존합니다. 이 표는 남은 작업 상태의 기준 문서입니다.

## 진행 상태: 안전성·복구·핵심 경로·사용량

엔진 소스만 변경했습니다. 기존 작업 저장소를 배포/이식하거나 실제 AI 작업을 실행하지 않았습니다.
현재 개발 저장소에는 여전히 활성 대상 프로필과 Git 커밋 baseline이 없습니다.

| 번호 | 개선 항목 | 진행 상태 |
| --- | --- | --- |
| 1 | 승인과 특정 변경 연결 | 구현: repository_root/source_branch/source_head/target_branch/stage 일치 검사. 요청·결정·승격·PR·로컬 merge·hook·감사 경로 반영 |
| 2 | 민감정보 유출 방지 | intake 복사 경로 수정. 민감정보 구역은 이름만 전달, 다른 구역의 흔한 키·암호 패턴 차단. 모든 런타임 로그의 범용 비밀값 탐지는 미완료 |
| 3 | 잠금과 소유권 보강 | OS lease 및 durable worker intent, 별도 worker host, 부모 종료 후 중복 실행 차단 구현. host 비정상 종료는 격리하며 자동 process-tree 종료와 네트워크 FS 검증은 미구현 |
| 4 | 자체 테스트·CI | 구문/JSON 및 격리 회귀 테스트, Windows PowerShell 5.1/7·Ubuntu 7 CI 정의 추가. 원격 CI는 아직 실행하지 않음 |
| 5 | 독립·이식 경로 통일 | 핵심 PowerShell과 개별 검증·cycle·retry shell 공통화. 기본 make fallback·인자 무시 제거. 특수문자 경로·인자, 다른 cwd, 복사 후 실제 Node CLI 실행 검사. 기타 설치/smoke shell 전체 통일과 플랫폼 실증은 별도 |
| 6 | Windows·WSL 안정화 | Windows PS5/7·CMD·Git Bash와 WSL2 Ubuntu native PowerShell/Bash 실증. 같은 fixture의 Windows→WSL→Windows hook 재설치·보호 commit 차단·도구 실행 확인. DrvFS Git 객체 복사 테스트 보완. 다른 배포판/물리 Linux 및 동시 OS 쓰기 검증은 남음 |
| 7 | 실제 실행 결과로 성공 판정 | 구현: 실제 validation 실행, code/HEAD/branch/index/log/assignment/invocation 연결, worker 종료·seed 승격 재검사. legacy pass는 미검증, 명시적 재검증 제공. 제품 의미상 정확성·악의적 로컬 위조·hermetic 환경 증명은 범위 밖 |
| 8 | 중단·복구와 상태 저장 | 원자적 파일 교체·workflow 충돌 거부, 큐 전환 journal·반복 복구·확인된 worker 종료 조정 구현. 최초 assignment/packet 생성과 외부 side effect의 전 과정 복구는 남음 |
| 9 | 작업별 사용량 측정 | invocation별 입력/캐시/출력 토큰·실행 시간·시도 기록 및 조회. Codex·Claude 수집 구현, 누락은 unknown/null. 실제 모델 판정·청구액은 남음 |
| 10 | 예산·시간·재시도 제한 | 예약 lease로 총 실행/동시 실행/assignment 시도 제한, 누적 토큰·시간에 따른 다음 실행 차단. 2026-10-21 실행 1회 시간 상한(`max_invocation_seconds`, watchdog이 provider 프로세스 트리 종료) 구현. 돈 단위 예산·실행 중 토큰 상한은 남음 |
| 11 | 단일 실행 명령 | 구현: init/doctor/run/status/resume/usage/test/dashboard/help, JSON v1, exit 0/1/2, 무변경 Preview, 명시적 재개 실행. dashboard 서버는 URL을 즉시 출력하고 Snapshot은 조회 JSON 제공. 나머지 명령의 실시간 출력·일부 고급 옵션은 남음 |
| 12 | Codex·Claude 어댑터 분리 | 두 adapter와 공통 요청/결과/usage v1 구현, worker/ledger/증거·복구 연결. 실패·incomplete Claude 결과·provider/model/ID 불일치 거부, 권한 우회 없음. 실제 유료 provider 검증은 남음 |
| 13 | 작업 분해·완료 조건 표준화 | 일부 구현: 고유 ID/상태/결과/validation 필드와 실행 증거 계약. 전체 작업 schema·의존성 DAG·완료 조건 의미 검사는 대기 |
| 14 | 전달 문맥 최소화 | 대기 |
| 15 | 설정·상태 형식 통일 | 대기 |
| 16 | 프로젝트별 검증 어댑터 | 대기 |
| 17 | 상태·실패 보고 개선 | 로컬 조회 현황판으로 작업·현재 증거·worker·사용량·승인·최근 사이클 통합. 미확정/부분 수집/오래된 화면 구분. 실행별/계획별 범위와 실시간 단계 이벤트는 대기 |
| 18 | 버전·업데이트·되돌리기 | 이번 변경의 전환 안내 작성. 자동 업데이트/되돌리기는 대기 |

## 검증 방법

```powershell
pwsh -NoProfile -File scripts/test_harness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test_harness.ps1
```

83개 PowerShell 스크립트의 구문과 설정 JSON을 검사합니다. 회귀 테스트는 지정한 출력 루트의 격리 폴더(기본 `.test-output/<run-id>/`)에만 테스트용 Git 저장소를 만들고 네트워크 없이 실행합니다. Shell 회귀에는 Node.js와 POSIX shell이 필요하며 진입점 비교에는 Bash, Windows에서는 CMD도 사용합니다. 테스트 fixture의 가짜 credential 문자열 외에 실제 credential은 사용하지 않습니다. `results.json`과 fixture는 진단을 위해 보존합니다.

두 번째 묶음 로컬 검증: Windows PowerShell 5.1과 PowerShell 7에서 각각 기존 안전성 23/23 및 복구 15/15 통과. 구문·JSON 검사도 통과했습니다. 상세 파일 경로는 [복구 검증 기록](archive/verification_2026-10-15.md)에 있습니다.

세 번째 묶음은 두 런타임 각각 안전성 23/23, 복구 16/16, 사용량 18/18, 경로 15/15 및 마지막 경계 사례를 확인했습니다. [최신 검증 기록](archive/verification_layout_usage_2026-10-15.md)에 실행별 근거를 남겼습니다.

네 번째 묶음은 두 런타임 각각 위 72개와 신규 실행 증거 28개를 포함한 **100/100**, 구문 71개·JSON 검사 및 feature commit 후 재검증을 통과했습니다. 최신 근거는 [실행 증거 검증 기록](archive/verification_evidence_2026-10-15.md)입니다.

다섯 번째 묶음은 기존 결과의 유닛·통합·보안 범위를 확인하고 신규 CLI 회귀를 두 런타임 각각 **25/25**(유닛 12·통합 8·보안 5), 구문 74개·JSON 검사로 검증했습니다. 전체 125개 재실행 결과와 구분하며 [CLI 검증 기록](archive/verification_cli_2026-10-15.md)에 남겼습니다.

여섯 번째 묶음은 최신 코드의 전체 회귀를 재실행하여 두 런타임 각각 **147/147**, 구문 77개·JSON 검사를 통과했습니다. 신규 provider 테스트는 각각 유닛 6/6·통합 4/4·보안 회귀 12/12입니다. 실행별 결과와 legacy 호환 근거는 [Provider 검증 기록](archive/verification_provider_2026-10-15.md)에 있습니다.

일곱 번째 묶음은 두 Windows 런타임 각각 기존 147/147과 최종 Claude 38/38(유닛 10·통합 9·보안 19), 구문 79개·JSON을 통과했습니다. PS5는 전체 183개 이후 마지막 타입 보강을 Claude 38개 재실행으로 검증했고 PS7은 전체 185개를 통과했습니다. [Claude 검증 기록](archive/verification_claude_2026-10-15.md)에 최종·중간 run을 구분했습니다.

여덟 번째 구현까지의 결과에는 실제 GitHub 인증·병합, 유료 Codex/Claude 실행, Docker, WSL/Linux 실행이 포함되지 않았습니다. 이후 플랫폼 추가 검증에서 WSL2 Ubuntu의 native Linux·Windows PS5/7·CMD·Bash·hook 재설치 전환을 실제 확인했습니다. 실행별 범위는 [최신 검증](archive/verification_platforms_2026-10-15.md)을 따릅니다. CI workflow 정의는 CI 실행 성공을 뜻하지 않습니다.

여덟 번째 묶음은 두 Windows 런타임에서 전체 **221/221**을 각각 재실행해 통과했습니다. 신규 shell은 유닛 4·통합 20·보안 12이며, 실제 Node CLI를 사용한 동일 재현 12개가 변경 전 0/12에서 변경 후 12/12로 바뀌었습니다. 구문 PS82·shell20·설정 JSON, 별도 실제 make 호환 2/2도 통과했습니다. [Shell 검증 기록](archive/verification_shell_2026-10-15.md)에 전후·중간 실패·전체 run을 구분했습니다.

이후 플랫폼 추가 검증은 Windows PS5/7 각각 진입점 30/30, Linux `/tmp` 기존 185/185·보강 shell36/36·진입점20/20, WSL 공유경로 `/mnt/c` shell36/36·진입점20/20입니다. 같은 fixture의 환경 전환 3단계와 수정한 이동 사례도 확인했습니다. 전체 runner 구성은 Windows251/Linux241이며 이번 분리 실행과 구분합니다. 실제 초기 실패 및 보존 근거는 [플랫폼 기록](archive/verification_platforms_2026-10-15.md)에 있습니다.

Intake 원본 파일의 내용을 지우거나 Git 이력을 정리하지는 않습니다. 원본에 이미 입력된 실제 값이 있다면 생성 문서의 필터링과 별도로 원본에서 제거해야 합니다.

## 전환 시 유의점

- 구형 승인은 `repository_root`가 없으므로 사용할 수 없습니다. 현재 위치에서 gate를 확인하고 승인을 새로 요청해야 합니다.
- 새 잠금의 `lease` 파일과 디렉터리는 정상 종료 후에도 남습니다. 활성 여부는 파일 존재가 아닌 `Test-HarnessLockActive`로 확인합니다.
- 구형 잠금은 소유자 확인이 불가능하므로 시간이 지나도 자동 삭제하지 않습니다. 구형 작업을 모두 종료하고 확인한 후 해당 잠금만 정리해야 합니다.
- `Acquire-HarnessLock`의 반환값은 경로 문자열로 변환 가능한 lease 객체입니다. `Release-HarnessLock`/`Update-HarnessLock`에는 원래 객체를 전달해야 합니다.
- 파일 시스템이 원자적 교체를 지원하지 않거나 권한이 없으면 쓰기는 실패합니다. 기존 파일을 덮어쓰는 비원자적 fallback은 제거했습니다.
- 로컬 승인 JSON과 hook은 협업 워크플로 통제이며 악의적인 로컬 쓰기 권한에 대한 보안 경계가 아닙니다.

## 다음 구현 순서

1. 전체 작업 정의 schema/의존성 DAG와 프로젝트별 검증 어댑터(13·16). 실행 증거(7), CLI(11)의 조회·실행 구분과 두 provider의 공통 예산/증거 계약(12)을 유지.
2. 추가 Linux 환경·원격 CI 실증. 이미 검증한 Windows/WSL2 Ubuntu 범위는 최신 기록을 유지. 실제 유료 provider 검증과 금액 예산·실행 중 timeout은 환경·정책을 확인하고 진행.
3. 불확실한 worker/usage 예약의 검토 후 조정 절차, 최초 생성/외부 side effect 복구 보강.

기존 worker를 종료·확인한 뒤 관련 스크립트를 함께 갱신합니다. 이전 버전은 새 큐 lease/journal을 준수하지 않습니다. [복구 설계와 명령](recovery_design.md)을 따르고 미확인 실행 기록을 삭제하지 않습니다.

## 18개 항목의 완료 기준과 남은 구현

아래 완료 기준은 다음 구현을 위한 제안입니다. 아직 적용하지 않은 정책이나 테스트 결과를 현재 보장으로 읽으면 안 됩니다. P0는 손상·누출·잘못된 병합 방지, P1은 반복 가능한 실행과 복구, P2는 확장성과 사용성을 기준으로 분류합니다.

| 번호·우선순위 | 후속 구현 및 완료 판정 기준 |
| --- | --- |
| 1 · P0 승인 범위 | 구현된 범위 검사를 유지. 실제 GitHub 연결 시 승인 이후 head 변경·draft·실패 check·target 변경을 서버 환경에서 확인. 로컬 기록 변조 방지와 서버 권한은 별개로 명시 |
| 2 · P0 민감정보 | 2026-10-21 worker 실행 로그·gate 로그·cycle 단계 로그·검증 증거 로그 마스킹(`secret_redaction.ps1`)과 가짜 credential 회귀 추가. 남음: retry prompt·보고서·artifact 경로 조사, 허용 필드 정책, 원본 intake 보존 정책 명시 |
| 3 · P0 잠금·소유권 | invocation ID와 프로세스 시작 시각을 이용해 부모/자식 수명 연결. 부모 종료 시 살아 있는 worker를 두고 중복 재실행하지 않도록 처리. PID 재사용·잘못된 프로세스 종료·두 복구자 경쟁 테스트. 네트워크 FS는 지원 또는 비지원 정책과 검증 근거 명시 |
| 4 · P1 자체 테스트·CI | 현재 로컬 회귀 유지. 원격 CI를 실제 실행하고 OS별 결과 기록. 생성·실행·재개를 아우르는 격리 smoke 확대. 플랫폼 미실행은 skip/unverified로 보고 |
| 5 · P1 경로 통일 | standalone 루트와 `<target>/harness`를 공통 함수로 해결. init/worker/hook/report에서 공백·한글·대괄호 경로 fixture 통과. 루트 탈출 차단 유지, 문서 명령도 두 배치에서 확인 |
| 6 · P1 Windows·WSL | shell 실행·인수 전달·인코딩·hook 경로를 검토. Windows 5.1/7, WSL/Linux smoke 및 환경 전환 후 hook 재설정 검증. 지원 범위를 문서에 고정 |
| 7 · P1 성공 판정 | 생성 파일 검사, 명령 실행 성공, 대상 동작 성공을 분리. 결과에 commit/명령/exit code/시간/증거를 연결하고 실제 실행 없이 완료하지 못하도록 검증. 오래된 결과·fake success 회귀 추가 |
| 8 · P1 상태·복구 | 원자적 파일 쓰기와 workflow 충돌 거부 유지. 큐 전환 journal에 intent/commit/recovery 정의. 목적 파일 생성 후 원본 삭제 전 중단, 중복 완료, 손상 상태, 복구자 경쟁에서 중복 실행·작업 유실이 없는지 검증 |
| 9 · P1 사용량 측정 | task/run/provider/model별 시간·재시도·알려진 토큰 기록. 실제치/추정치/미제공 구분. API 청구와 구독 사용량을 분리하고 없는 수치를 0 또는 비용 확정값으로 기록하지 않음 |
| 10 · P1 제한·중단 | 작업/전체 run의 시간·재시도·예산 상한과 제한 도달 시 pause/resume 구현. rate limit backoff, 중복 청구 위험이 있는 재실행을 다룸. 가격표 버전 및 사용량 미제공 시 동작 결정. 9번에 의존 |
| 11 · P2 CLI 통합 | init/doctor/run/status/resume 진입점과 help/일관된 exit code 제공. 기존 script 호출 호환 및 변경 안내, 안전한 preview 검증. 실제 wrapper 범위는 구현 전에 결정 |
| 12 · P2 provider 어댑터 | Codex·Claude 및 fake 계약 테스트 구현 완료. 후속으로 실제 환경의 권한·프로토콜 호환을 별도 승인 범위에서 검증. 인증·과금 방식과 미지원 필드를 명시하며 사용량·제한·완료 계약 유지 |
| 13 · P2 작업 정의 | 작업 ID, 의존성, 담당자, 허용 범위, 완료 조건, 검증 명령을 schema로 검증. 순환 의존성·모호한 완료 조건·중복 ID를 실행 전에 거부 |
| 14 · P2 문맥 최소화 | task에 필요한 파일·실패 증거만 전달하고 전체 로그 중복을 제한. 관련 오류 유실 여부와 토큰 감소를 함께 측정. secret 필터를 우회하지 않음 |
| 15 · P2 형식 통일 | profile/assignment/state/report의 schemaVersion과 validation, 단일 기준 데이터 정의. legacy 읽기·마이그레이션·알 수 없는 버전의 명시적 거부 테스트. 담당자 예시 불일치 정리 |
| 16 · P2 검증 어댑터 | 프로젝트 유형별 build/unit/integration/benchmark 계약과 필수·선택 검증 구분. 최소 두 유형 fixture로 성공/실패/미설정 검증. 현재 미구성 프로필을 임의로 제품 설정하지 않음 |
| 17 · P2 보고 | 큐·실행·실패 원인·다음 조치·검증·usage를 run ID로 연결한 공통 JSON/사람용 요약 제공. 실패/중단/unverified를 구분하고 credential이 노출되지 않음 |
| 18 · P2 버전·전환 | engine version, 변경 이력, 설치 상태 검사와 migration 제공. 대상 프로젝트 사용자 설정을 보존하는 업데이트·되돌리기 fixture 검증. 기존 승인 무효화와 legacy lock 절차 포함 |

## 두 번째 구현의 조사 지도

- 잠금과 파일 저장: `scripts/harness_common.ps1`의 Acquire/Release/Update/Test-HarnessLockActive 및 Move-FileWithUpdatedContent.
- 작업자와 복구: `scripts/invoke_assignment_codex.ps1`, `scripts/invoke_pending_assignment_codex.ps1`, `scripts/run_seed_handoff.ps1`, `scripts/get_seed_handoff_resume.ps1`을 시작점으로 실제 호출 관계 추적.
- 테스트 확장: `scripts/test_harness_recovery.ps1`, `scripts/test_recovery_child.ps1`에서 fake worker가 살아 있는 동안 부모/host를 종료한 경우와 큐 중단을 검증했습니다. 실제 AI CLI 검증은 아닙니다.
- 완료한 재현: 부모 강제 종료 + 살아 있는 worker, 큐 목적 파일 생성 직후 중단, journal 기록 직후 중단, 완료 기록 직전 중단, 동시에 복구하는 두 프로세스.
- 복구는 반복 실행해도 같은 결과가 되어야 하며 상태 파일의 존재만으로 worker가 종료됐다고 판단하지 않아야 함.

이 작업에는 실제 유료 AI나 외부 알림 없이 fake worker/격리 Git fixture를 먼저 사용할 수 있습니다. 실제 서비스 시험은 그 단계의 환경과 사용자 지시를 확인한 뒤 범위를 정합니다.
