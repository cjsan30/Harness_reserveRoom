# Harness 구현 기능 전체 목록

현재 소스에 존재하는 기능을 분류한 목록입니다. **29개 기능군, PowerShell 92개와 shell 19개로 구성된 스크립트 111개**, 추가 Python 2개·브라우저 회귀 JS 1개, Git hook 템플릿 4종을 포함합니다.

구현 존재와 검증 완료는 다릅니다. 현재 개발 저장소에는 활성 대상 프로필이 없으며 알려진 결함은 현재 상태에 기록되어 있습니다. 생성 파일 감사는 일부 항목에서 필수 문자열 존재를 확인하는 수준입니다.

## 1. 이식 및 실행 환경

Windows/POSIX 경로 변환, PowerShell 탐색, WSL의 native pwsh 요구, XDG 캐시 경로 준비, shell 실행 권한 및 hook 설치.

| 구현 파일 | 역할 |
| --- | --- |
| [setup_portable_runtime.sh](../scripts/setup_portable_runtime.sh) | 이식된 대상의 shell 실행 권한, PowerShell 환경, hook 및 preflight 준비 |
| [resolve_powershell.sh](../scripts/resolve_powershell.sh) | 환경 변수·PATH·사용자 설치 경로에서 PowerShell 선택 |
| [path_common.sh](../scripts/path_common.sh) | Windows·Git Bash·WSL 사이의 shell/PowerShell 경로 변환 |
| [powershell_env.sh](../scripts/powershell_env.sh) | POSIX PowerShell의 쓰기 가능한 XDG 캐시·데이터·설정 경로 준비 |

## 2. 프로젝트 어댑터

프로젝트 식별 정보, 요구사항, 언어·프레임워크, 검증 명령, 담당자 구성을 생성합니다. C/C++, Node/JavaScript/TypeScript, Python, Java/Kotlin, .NET, Go, Rust 프리셋과 요구사항 기반 추론·대화식 입력이 있습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [init_project_adapter.ps1](../scripts/init_project_adapter.ps1) | 프리셋 목록·추론·선택, 프로필/프롬프트/기본 문서/ignore/attributes 초기화 |
| [generate_profile_docs.ps1](../scripts/generate_profile_docs.ps1) | 활성 프로필의 설정·명령·담당자 문서 생성 |

## 3. 요구사항 접수 및 시작

Intake 템플릿, 누락·모호성 질문, 외부 환경 준비와 Git baseline 검사, 질문 보류 정책, 명령 override, seed 계획 생성 및 dry-run 연결을 제공합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [start_from_intake.ps1](../scripts/start_from_intake.ps1) | 템플릿 생성, intake 리뷰, 어댑터 초기화, 요구사항·환경 문서·seed 계획 생성 |
| [review_project_intake.ps1](../scripts/review_project_intake.ps1) | 요구사항/준비 상태 검토, 질문·보고서 작성 및 불완전 입력 차단 |
| [generate_env_manifest.ps1](../scripts/generate_env_manifest.ps1) | 환경 변수 목록, .env.example, 환경 문서와 민감정보 후속 조치 문서 생성 |

## 4. 사전 검사 및 저장소 위생

프로필 필수 항목, 경로 경계, 실행 명령, 쓰기 가능 여부, 필수 스크립트·hook, Git 상태, 이식 구조와 생성물 포함 여부를 검사합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [run_harness_preflight.ps1](../scripts/run_harness_preflight.ps1) | 운영 준비 상태 검사와 결과 보고서 생성 |
| [audit_porting_layout.ps1](../scripts/audit_porting_layout.ps1) | 중첩/독립 루트 구조 및 필수 경로 검사 |
| [audit_generated_artifacts.ps1](../scripts/audit_generated_artifacts.ps1) | 생성된 보고서·상태·작업 큐의 staged 여부와 ignore 정책 검사 |

## 5. 검증 사이클

build → unit → integration → benchmark smoke 순서로 실행하고 실패 이후 단계를 중단합니다. 단계 로그, 최신 결과, 누적 증거를 기록합니다. 검증 명령은 대상 프로필에서 제공해야 합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [run_harness_cycle.ps1](../scripts/run_harness_cycle.ps1) | 프로필 기반 순차 검증, 실패 분류, 단계별 기록 및 재시도 프롬프트 연결 |
| [run_harness_cycle.sh](../scripts/run_harness_cycle.sh) | PowerShell 검증 사이클의 POSIX 진입점 |
| [run_build.sh](../scripts/run_build.sh) | 프로필 기반 build 실행 및 preview |
| [run_unit.sh](../scripts/run_unit.sh) | 프로필 기반 unit 실행 및 preview |
| [run_integration.sh](../scripts/run_integration.sh) | 프로필 기반 integration 실행 및 preview |
| [run_benchmark_smoke.sh](../scripts/run_benchmark_smoke.sh) | 프로필 기반 benchmark smoke 실행 및 preview |

## 6. 실패 분석 및 재시도

로그 패턴과 프로필을 이용한 compile/interface/logic/environment/secret/requirements/worker 관련 분류, 담당자 선택, 실패 이력과 반복 실패 처리, 재시도 지시문·배정 패킷 생성이 있습니다. missing-test는 정책상의 분류이며 모든 분류가 독립된 자동 탐지기를 갖는 것은 아닙니다.

| 구현 파일 | 역할 |
| --- | --- |
| [generate_retry_prompt.ps1](../scripts/generate_retry_prompt.ps1) | 최신 실패 결과를 담당자·검증·다음 작업이 포함된 프롬프트로 변환 |
| [generate_retry_prompt.sh](../scripts/generate_retry_prompt.sh) | 재시도 프롬프트 생성의 POSIX 진입점 |
| [dispatch_retry_prompt.ps1](../scripts/dispatch_retry_prompt.ps1) | 중복 배정 검사, 재시도 작업 큐·패킷 생성 및 선택적 worker 실행 |
| [run_retry_handoff.ps1](../scripts/run_retry_handoff.ps1) | 재시도 생성부터 배정·worker 실행까지 연결 |

## 7. 작업 큐 생명주기

담당자별 inbox → in_progress → done 상태 전환, pass/fail 완료, 전환 로그와 잠금을 제공합니다. 잠금은 OS 파일 핸들과 실행별 소유권으로 관리하며 시간 경과만으로 제거하지 않습니다. 상태 전환 도중 중단되어 파일 두 개가 남는 경우의 완전한 복구는 별도 개선 과제입니다.

| 구현 파일 | 역할 |
| --- | --- |
| [claim_assignment.ps1](../scripts/claim_assignment.ps1) | 대기 작업 선택 및 시작 상태 전환 |
| [complete_assignment.ps1](../scripts/complete_assignment.ps1) | 진행 중 작업의 pass/fail 완료와 상태 파일 이동 |

## 8. Codex 작업자 실행

codex exec에 전달할 컨텍스트와 프롬프트를 구성하고 작업별 feature branch/worktree에서 실행합니다. DryRun, PreflightOnly, Model, Ephemeral 옵션과 실행 로그·최종 메시지·완료 여부 검사가 있습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [invoke_assignment_codex.ps1](../scripts/invoke_assignment_codex.ps1) | 작업별 Codex CLI 실행, 격리 공간 및 실행 잠금 관리, 미완료 작업 실패 처리 |
| [invoke_pending_assignment_codex.ps1](../scripts/invoke_pending_assignment_codex.ps1) | 담당자의 가장 오래된 대기 작업 선택 후 실행 |

## 9. Seed 계획 및 재개

Markdown seed 계획을 작업으로 분해해 순차 실행합니다. 재시도 횟수, 실패 시 중단/계속, 완료 작업 건너뛰기, 실패 재배정, 활성 작업 중복 실행 방지, dev 통합과 최종 후보 생성까지 연결합니다. main 승인·병합은 seed 흐름에서 자동 수행하지 않습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [dispatch_seed_plan.ps1](../scripts/dispatch_seed_plan.ps1) | 계획 파싱, 배정·재시도·재개, 통과한 작업을 즉시 `dev`로 승격(다음 작업은 `dev`에서 출발), 병합된 작업 worktree·브랜치 정리 |
| [run_seed_handoff.ps1](../scripts/run_seed_handoff.ps1) | hook 갱신·preflight·계획 실행을 한 진입점으로 연결 |
| [get_seed_handoff_resume.ps1](../scripts/get_seed_handoff_resume.ps1) | 완료/대기/실행/실패/누락/복구 상태와 재개 명령을 Markdown·JSON으로 기록 |

## 10. 로컬 Git 통제

feature/integration/final/bootstrap gate, 보호 브랜치 정책, 검증 tree 기록, 승격 승인, 초기 baseline 흐름을 구현합니다. 승인 ID와 현재 branch/head의 결합 검사는 알려진 미완료 과제입니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_git_hooks.ps1](../scripts/install_git_hooks.ps1) | hook 템플릿 설치와 core.hooksPath 설정 |
| [assert_git_action_allowed.ps1](../scripts/assert_git_action_allowed.ps1) | commit/push/merge/rebase의 정책 및 관련 증거 검사 |
| [audit_git_workflow.ps1](../scripts/audit_git_workflow.ps1) | 브랜치·검증·승격·승인 상태 감사 |
| [run_git_gate.ps1](../scripts/run_git_gate.ps1) | feature/integration/final/bootstrap 검증 및 증거 기록. 명령은 설정에서만 읽고 make·pwsh 대체 실행 없음 |
| [approve_branch_deletion.ps1](../scripts/approve_branch_deletion.ps1) | 병합되지 않은 feature/test 원격 브랜치 삭제에 대한 사용자 승인 기록(저장소·remote·브랜치·head 결합). main/dev는 거부 |
| [run_self_gate.ps1](../scripts/run_self_gate.ps1) | 엔진 저장소 자체 gate: feature는 PS5.1·PS7 구문 검사, integration은 두 런타임 전체 회귀, final은 여기에 현황판 HTTP 회귀 추가 |
| [.harness/self_workflow.json](../.harness/self_workflow.json) | 프로필이 없는 엔진 저장소 전용 Git 정책(owner·gate 명령). 엔진이 저장소 루트에 있을 때만 사용 |
| [bootstrap_initial_commit.ps1](../scripts/bootstrap_initial_commit.ps1) | 최초 커밋 계획, 검증·승인 및 명시적 커밋/푸시 옵션 |
| [request_main_merge_approval.ps1](../scripts/request_main_merge_approval.ps1) | main 통합 후보에 대한 승인 요청 기록 |
| [set_main_merge_approval.ps1](../scripts/set_main_merge_approval.ps1) | 승인 요청의 승인/거절 상태 기록 |
| [authorize_branch_promotion.ps1](../scripts/authorize_branch_promotion.ps1) | 검증과 승인에 따른 보호 브랜치 승격 허가 기록 |
| [merge_authorized_branch.ps1](../scripts/merge_authorized_branch.ps1) | 예정된 source branch/head를 hook에 전달하는 승인된 병합 실행 |

## 11. Git/GitHub 인증 진단

Git remote 접근, gh CLI 인증, 선택적 GitHub API 접근을 별도 상태로 기록합니다. 읽기 접근 성공은 원격 쓰기 권한의 보증이 아닙니다.

| 구현 파일 | 역할 |
| --- | --- |
| [audit_git_remote_auth.ps1](../scripts/audit_git_remote_auth.ps1) | remote/CLI/API 상태 진단 및 필수 조건 옵션 처리 |

## 12. GitHub PR 제어

후보 push 및 PR 생성/조회, 필수 check 판정, 최종 gate·승인·PR head 조건에 따른 병합 요청을 제공합니다. merge/squash/rebase/queue/auto 방식이 있습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [open_pr_candidate.ps1](../scripts/open_pr_candidate.ps1) | 후보 브랜치 push, PR 작성 또는 기존 PR 처리와 보고 |
| [check_pr_status.ps1](../scripts/check_pr_status.ps1) | PR 및 required/all checks 상태 집계 |
| [merge_pr_if_allowed.ps1](../scripts/merge_pr_if_allowed.ps1) | gate·승인·검사 조건 확인 후 head 고정 병합 요청 |

## 13. GitHub 서버 보호 규칙

main 대상 ruleset 생성·갱신·감사, 삭제/강제 push 제한, PR·승인 수·strict required check, 선택적 code owner review와 merge queue 설정을 제공합니다. `-Branch dev -ProtectionOnly`는 dev처럼 로컬 승인 merge로 갱신되는 브랜치에 삭제·강제 push 금지만 거는 별도 ruleset(`Harness dev Protection`)을 만들며, main에는 거부되고 다른 브랜치를 보호하는 같은 이름 ruleset을 덮어쓰지 않습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_github_ruleset.ps1](../scripts/install_github_ruleset.ps1) | GitHub API를 통한 ruleset 설치/갱신 (`-Branch`, `-ProtectionOnly`) |
| [audit_github_policy.ps1](../scripts/audit_github_policy.ps1) | 저장소 ruleset과 요구 정책의 일치 여부 검사 (`-Branch`, `-ProtectionOnly`) |

## 14. 개발 환경 생성

프로필의 언어·런타임에 따른 devcontainer, toolchain manifest, 편집기 확장과 선택적 mise 설정을 생성하고 필수 내용을 검사합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_dev_environment.ps1](../scripts/install_dev_environment.ps1) | 개발 환경 구성 파일 생성 |
| [audit_dev_environment.ps1](../scripts/audit_dev_environment.ps1) | 개발 환경 구성 파일의 정합성 검사 |

## 15. 서비스 의존성

서비스 계약과 Docker Compose 구성을 생성하고 실행합니다. postgres/redis 조합 프리셋, 환경 변수 이름, healthcheck·준비 조건과 status/up/down·DryRun이 있습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_service_contract.ps1](../scripts/install_service_contract.ps1) | 서비스 계약·Compose·설명 문서 생성 |
| [audit_service_contract.ps1](../scripts/audit_service_contract.ps1) | 계약 및 Compose 구성 검사 |
| [run_service_contract.ps1](../scripts/run_service_contract.ps1) | Docker Compose 상태 조회·시작·중지 또는 실행 명령 미리보기 |

## 16. CI 생성 및 검사

프로필 기반 GitHub Actions workflow, 런타임 설정, matrix·cache, 서비스 시작/정리, Harness CI 집계 check를 생성합니다. 기본 matrix는 Ubuntu 기반이며 플랫폼 전체 검증을 뜻하지 않습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_github_actions_workflow.ps1](../scripts/install_github_actions_workflow.ps1) | Harness CI workflow 생성 |
| [audit_ci_matrix.ps1](../scripts/audit_ci_matrix.ps1) | workflow의 matrix/cache/집계/service 단계 필수 표시 검사 |

## 17. 릴리스 증거

release 명령, 산출물 수집·업로드, artifact attestation workflow를 생성합니다. 검사는 실제 배포나 attestation 성공을 보증하지 않습니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_release_provenance_workflow.ps1](../scripts/install_release_provenance_workflow.ps1) | 릴리스 산출물·출처 증명 workflow 생성 |
| [audit_release_provenance.ps1](../scripts/audit_release_provenance.ps1) | 권한·업로드·attestation·산출물 경로 등 필수 표시 검사 |

## 18. 보안 및 가벼운 품질 검사

언어별 Dependabot, 지원 언어의 CodeQL, OpenSSF Scorecard, 선택적 GitHub 보안 설정 감사와 pre-commit 구성을 제공합니다. pre-commit에는 공백/줄 끝/JSON/YAML/대용량 파일/개인키/줄바꿈 검사와 언어별 local hook이 포함됩니다.

| 구현 파일 | 역할 |
| --- | --- |
| [install_security_baseline.ps1](../scripts/install_security_baseline.ps1) | Dependabot/CodeQL/Scorecard 및 baseline 설명 생성 |
| [audit_security_baseline.ps1](../scripts/audit_security_baseline.ps1) | 보안 파일과 선택적 서버 설정 검사 |
| [install_precommit_baseline.ps1](../scripts/install_precommit_baseline.ps1) | pre-commit 구성 및 사용 문서 생성 |
| [audit_precommit_baseline.ps1](../scripts/audit_precommit_baseline.ps1) | 가벼운 품질 검사 baseline 확인 |

## 19. 상태 및 알림

상태·진행 단계·실패·사용자 조치 필요 여부·다음 명령을 Markdown/JSON으로 기록합니다. Telegram은 attention/action_required/failure/all 수준, 중복 억제, 강제 전송, DryRun, 비활성화 옵션을 제공합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [get_harness_status.ps1](../scripts/get_harness_status.ps1) | 상태 snapshot, 작업 수·보고서·다음 행동 집계 및 선택적 알림 연결 |
| [send_harness_notification.ps1](../scripts/send_harness_notification.ps1) | Telegram 전송 판단·중복 억제·로그 기록 |

## 20. 격리된 smoke 테스트

임시 대상 저장소에서 기능을 검증하는 7종 테스트가 있습니다. worker·GitHub 관련 테스트는 fake 실행기를 사용하며 실제 서비스 성공과 구분합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [run_portable_smoke.sh](../scripts/run_portable_smoke.sh) | 이식·초기화·runtime setup·hook 설치 검사 |
| [run_operational_smoke.sh](../scripts/run_operational_smoke.sh) | 재시도·배정·완료·재개 및 fake Codex 동작 검사 |
| [run_git_hook_smoke.sh](../scripts/run_git_hook_smoke.sh) | 보호 커밋·push·승인된 병합 경로 검사 |
| [run_pr_control_smoke.sh](../scripts/run_pr_control_smoke.sh) | fake gh를 통한 PR 생성·check·병합 제어 검사 |
| [run_github_policy_smoke.sh](../scripts/run_github_policy_smoke.sh) | fake GitHub API를 통한 ruleset 설치·감사 검사 |
| [run_platform_engineering_smoke.sh](../scripts/run_platform_engineering_smoke.sh) | 개발 환경·서비스·CI·릴리스 생성 및 검사 |
| [run_security_quality_smoke.sh](../scripts/run_security_quality_smoke.sh) | 보안 및 pre-commit 생성·감사 검사 |

## 21. 공통 내부 기능

JSON 프로필과 Markdown 상태, UTF-8 쓰기, 경로 제한, 프로세스 실행, 잠금·오래된 작업 복구, 실패 서명, Git/worktree 및 API 모델을 제공합니다.

| 구현 파일 | 역할 |
| --- | --- |
| [harness_common.ps1](../scripts/harness_common.ps1) | 설정·경로·쓰기·프로세스·보고서·잠금·배정·실패 이력 공통 함수 |
| [git_workflow_common.ps1](../scripts/git_workflow_common.ps1) | Git 상태·브랜치·tree·worktree·검증·승격·승인 공통 함수 |
| [github_pr_common.ps1](../scripts/github_pr_common.ps1) | gh 탐색·호출·JSON·PR/check 상태 공통 함수 |
| [github_policy_common.ps1](../scripts/github_policy_common.ps1) | GitHub repository/ruleset 조회·정책 판정·payload 생성 |
| [platform_engineering_common.ps1](../scripts/platform_engineering_common.ps1) | 언어별 런타임·개발 환경·CI·캐시 모델 생성 |
| [security_quality_common.ps1](../scripts/security_quality_common.ps1) | 언어별 보안 도구와 workflow/pre-commit 템플릿 생성 |

## Git hook 템플릿 4종

| 템플릿 | 검사 대상 |
| --- | --- |
| [pre-commit](../githooks/pre-commit) | 커밋 브랜치와 검증 조건 |
| [pre-push](../githooks/pre-push) | 실제 ref update와 보호 브랜치 push |
| [pre-merge-commit](../githooks/pre-merge-commit) | 보호 브랜치 병합과 승격·승인 증거 |
| [pre-rebase](../githooks/pre-rebase) | 보호 브랜치 rebase |

.git/hooks 또는 .githooks에 파일이 존재하는 것과 Git에 활성화되는 것은 별개입니다.

## 템플릿과 정책 문서

- [프로젝트 프로필](../configs/project_profile.template.json): 프로젝트·명령·담당자·실패 패턴·Git·산출물 경로
- [Intake](project_intake.template.md): 요구사항, 성공 기준, 환경 및 초기 작업 계획
- [담당자 계획](subagent_plan.template.md), [첫 지시문](subagent_first_prompts.template.md), [seed 계획](../project/prompts/manager_main_seed.md)
- [Git 정책](../configs/git_policy.md), [재시도 정책](../configs/retry_dispatch_policy.md), [기능 체크리스트](../configs/harness_checklist.md)
- [결과 보고서](../reports/report_template.md), [재시도 프롬프트](../reports/retry_prompt_template.md)
- [알림 설정](../configs/notification.template.json), [ignore](../configs/gitignore.template), [attributes](../configs/gitattributes.template)

## 22. 엔진 자체 회귀 검증과 intake 안전 처리

| 구현 파일 | 역할 |
| --- | --- |
| [test_harness.ps1](../scripts/test_harness.ps1) | PowerShell 구문·JSON 검사와 안전성 테스트의 공통 진입점 |
| [test_harness_safety.ps1](../scripts/test_harness_safety.ps1) | 격리 Git 저장소, fake GitHub CLI, 별도 프로세스로 승인·민감정보·잠금·원자적 저장 검증 |
| [test_project_adapter.ps1](../scripts/test_project_adapter.ps1) | Java 프리셋 wrapper 명령·표준 경로, worker 문서 목록, 기존 ignore 파일 병합, 문서 템플릿 치환, preflight 자리표시자 경고, bootstrap 템플릿 후보 |
| [test_git_workflow_policy.ps1](../scripts/test_git_workflow_policy.ps1) | 브랜치 이름 기본값, 자체 정책 적용 범위, gate 명령 fail-closed, 커밋 규칙, 병합된 브랜치 원격 삭제·승인된 미병합 브랜치 삭제, fake gh로 dev 보호 ruleset 생성·main 보호 유지 검증 |
| [test_lock_child.ps1](../scripts/test_lock_child.ps1) | 강제 종료·동시 잠금 테스트 전용 자식 프로세스 |
| [intake_safety.ps1](../scripts/intake_safety.ps1) | 민감정보 구역에서 변수 이름만 전달하고 다른 구역의 흔한 credential 패턴 차단 |

## 23. Worker 수명 기록과 큐 전환 복구

| 구현 파일 | 역할 |
| --- | --- |
| [assignment_state.ps1](../scripts/assignment_state.ps1) | 큐 lease/journal/복구, worker intent와 종료 조정 공통 함수 |
| [run_assignment_worker.ps1](../scripts/run_assignment_worker.ps1) | 부모와 별도인 worker host, worker lease 및 직접 로그 기록 |
| [repair_assignment_state.ps1](../scripts/repair_assignment_state.ps1) | 미완료 큐 journal 및 확인된 worker 종료 복구 명령 |
| [test_harness_recovery.ps1](../scripts/test_harness_recovery.ps1) | 강제 종료·중복 실행 차단·충돌·실제 invoke 진입점의 fake worker 회귀 |
| [test_recovery_child.ps1](../scripts/test_recovery_child.ps1) | 큐 중단·경쟁 복구·부모/worker 수명 테스트 전용 프로세스 |

설계와 지원 범위는 [복구 설계](recovery_design.md)에 있습니다.

## 24. 경로 통일·사용량 기록·다음 실행 제한

| 구현 파일 | 역할 |
| --- | --- |
| [harness_layout.ps1](../scripts/harness_layout.ps1) | 독립·이식 엔진 위치, 알려진 프로필 경로와 생성 지시문 변환 |
| [hook_bootstrap.sh](../scripts/hook_bootstrap.sh) | main checkout 및 isolated worktree의 공유 정책 루트 |
| [test_harness_layout.ps1](../scripts/test_harness_layout.ps1) | 두 배치의 한글·공백·대괄호 경로, 실제 hook/cycle, fake worker 및 생성 파일 검증 |
| [execution_usage.ps1](../scripts/execution_usage.ps1) | 실행 전 예약, JSONL 사용량·실행 시간·시도 이력, 공통 lease 안에서 정책 검사 |
| [worker_timeout_watchdog.ps1](../scripts/worker_timeout_watchdog.ps1) | `max_invocation_seconds` 초과 시 timeout 기록 후 worker host의 하위 프로세스 트리만 종료. host PID 시작 시각 확인 |
| [secret_redaction.ps1](../scripts/secret_redaction.ps1) | worker·gate·cycle·검증 증거 로그를 쓰기 전 비밀값을 `[REDACTED]`로 마스킹. 사용량 수치는 유지 |
| [get_execution_usage.ps1](../scripts/get_execution_usage.ps1) | 보존된 전체 실행의 합계와 실행별 JSON 조회 |
| [test_execution_usage.ps1](../scripts/test_execution_usage.ps1) | 미확인 사용량, 손상 기록, 한도·경쟁 예약 및 조회 명령 회귀 |

실제 모델·청구액·구독 잔여량을 추정하지 않습니다. [정책과 한계](execution_usage.md), [배치 지원](layout_support.md)을 참고하세요.

## 25. 실행 증거 기반 작업 성공 판정

| 구현 파일 | 역할 |
| --- | --- |
| [assignment_evidence.ps1](../scripts/assignment_evidence.ps1) | 실제 검증 실행, Git·소스 snapshot, 로그·assignment·worker 연결 및 재검사 |
| [test_assignment_evidence.ps1](../scripts/test_assignment_evidence.ps1) | 거짓 pass, 실패/오래된 증거, source/log 변경, 재검증, seed 소비 경로 회귀 |

기존 complete/invoke/복구/seed/status 경로에 연결했습니다. 명령 실행 성공과 제품 동작의 독립 검증은 구분합니다. [계약·명령·한계](assignment_evidence.md)를 참고하세요.

## 26. 단일 운영 CLI

| 구현 파일 | 역할 |
| --- | --- |
| [harness.ps1](../scripts/harness.ps1) | init/doctor/run/status/resume/usage/test/help 진입점, JSON 응답과 종료 코드 |
| [harness_cli.ps1](../scripts/harness_cli.ps1) | 허용 옵션 해석, 경로·호출 계획, 인수를 데이터로 전달하는 하위 실행 |
| [test_harness_cli.ps1](../scripts/test_harness_cli.ps1) | 유닛·통합·보안 범주의 두 배치 CLI 회귀 |

[CLI 계약](cli.md)을 참고하세요. provider 분리와 공통 shell 진입점은 다음 항목에 있습니다.

## 27. Provider 실행·결과·사용량 계약

| 구현 파일 | 역할 |
| --- | --- |
| [provider_contract.ps1](../scripts/provider_contract.ps1) | 버전이 있는 요청/결과, provider 선택과 ID·모델·사용량 정합성 검사, 구형 기록 호환 |
| [provider_codex.ps1](../scripts/provider_codex.ps1) | Codex 실행 파일·인수·버전과 JSONL 응답/사용량 해석 |
| [provider_claude.ps1](../scripts/provider_claude.ps1) | Claude print 실행·권한 인수·최종 결과·캐시 사용량 정규화 |
| [test_provider_contract.ps1](../scripts/test_provider_contract.ps1) | 유닛·통합·보안 계약 회귀, 실제 worker host와 fake provider 검증 |
| [test_provider_claude.ps1](../scripts/test_provider_claude.ps1) | Claude 유닛·통합·보안, 두 배치 완료·복구·예산·UTF-8 회귀 |

host·usage ledger·완료 증거·복구에 연결했습니다. exit 0인 명시적 provider 실패도 성공으로 인정하지 않습니다. Codex와 Claude를 지원하며 실제 유료 호출 검증은 남아 있습니다. [공통 계약](provider_contract.md), [Claude 권한·사용량·전환](claude_adapter.md)을 참고하세요.

## 28. 공통 Shell 명령 진입점

| 구현 파일 | 역할 |
| --- | --- |
| [invoke_harness.sh](../scripts/invoke_harness.sh) | 고정 action registry, 허용 옵션·런타임·경로 변환과 MSYS 재변환 방지 |
| [run_harness_shell.ps1](../scripts/run_harness_shell.ps1) | 설치 프로젝트 경계, preview, 개별 단계·cycle·retry 연결 및 종료 코드 전달 |
| [validation_command.ps1](../scripts/validation_command.ps1) | 단계별 프로필 명령 검사·make 해석·재귀 거부·공통 실행 |
| [test_harness_shell.ps1](../scripts/test_harness_shell.ps1) | 다른 격리 프로젝트의 실제 Node CLI 유닛·통합·보안 회귀 |
| [test_harness_entrypoints.ps1](../scripts/test_harness_entrypoints.ps1) | PowerShell 직접 호출·CMD·Bash의 실제 인자/경로/preview/종료 코드/사이클 비교; Linux에서는 native PowerShell·Bash |

기본 make fallback과 알 수 없는 인자 무시를 제거했습니다. [명령 계약과 전환](shell_commands.md), 실제 전후 비교를 참고하세요.

## 29. 로컬 조회 현황판

| 구현 파일 | 역할 |
| --- | --- |
| [get_harness_dashboard.ps1](../scripts/get_harness_dashboard.ps1) | 조회 전용 snapshot, 현재 증거 확인, worker 생존 관측, 사용량·승인·검증 기록 집계 |
| [start_harness_dashboard.ps1](../scripts/start_harness_dashboard.ps1) | Python/PowerShell 경로를 개별 인수로 전달하는 foreground launcher |
| [harness_dashboard_server.py](../scripts/harness_dashboard_server.py) | loopback 전용 캐시 API, Host/Origin/메서드/경로 제한 |
| [assignment_state.ps1](../scripts/assignment_state.ps1), [run_assignment_worker.ps1](../scripts/run_assignment_worker.ps1) | Linux 커널 프로세스 식별자를 선택 필드로 기록하여 시계 보정에 독립적으로 가동 상태 관측 |
| [화면](../dashboard/index.html), [스타일](../dashboard/style.css), [동작](../dashboard/app.js) | 자동 갱신, 작업 상세·필터, 불확실/오래된 상태와 사용량 표시 |
| [test_harness_dashboard.ps1](../scripts/test_harness_dashboard.ps1) | 두 배치의 CLI·완료 증거·PID·사용량·읽기 전용·경로 경계 검사 |
| [test_harness_dashboard_server.py](../scripts/test_harness_dashboard_server.py) | HTTP·수집 오류 보존·외부 Origin/경로/변경 요청 차단 |
| [test_harness_dashboard_browser.js](../scripts/test_harness_dashboard_browser.js) | 실제 브라우저의 상세·필터·XSS·반응형·연결 복구 검사 |

[명령과 지표 계약](dashboard.md). `harness.ps1 dashboard` 및 `dashboard -Snapshot -Json`으로 접근합니다.

## 구현 범위의 경계

- Seed worker는 순차 실행이며 병렬 스케줄러가 아닙니다.
- 기존 status는 보고서와 알림을 갱신합니다. 별도의 조회 전용 웹 현황판은 foreground 서버로 실행하며 OS 상주 서비스로 설치하지 않습니다.
- 실제 Codex 실행, 원격 PR/ruleset, Telegram, Docker는 각각 설치·인증·환경 구성이 필요합니다.
- build/unit/integration/benchmark의 실제 내용은 대상 프로필이 정합니다. Harness에 모든 프로젝트의 테스트가 내장된 것은 아닙니다.
- smoke 테스트의 fake worker/API 통과는 실제 Codex 또는 GitHub 실행의 검증과 같지 않습니다.
- 승인 범위와 intake 민감정보 복사 경로는 회귀 테스트와 함께 수정했습니다. 핵심 독립/이식 경로·shell 명령 통일 및 사용량/다음 실행 제한을 추가했습니다. Windows·WSL2 Ubuntu의 실제 플랫폼 검증을 수행했으며 금액 예산, 실행 중 timeout, 별도 Linux 배포판·원격 CI는 남아 있습니다.
- 부모 종료 후 worker lease와 실행 기록으로 중복 실행을 차단합니다. 종료가 불명확한 자식 프로세스의 강제 정리, 네트워크 파일시스템 잠금은 제공·검증 범위 밖입니다.
