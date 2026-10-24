# Harness Improvement

AI 코딩 작업의 배정, 검증, 실패 복구, Git 통합을 관리하는 Portable Harness의 개선 전용 저장소입니다.

로컬 조회 현황판: `pwsh -NoProfile -File scripts/harness.ps1 dashboard`.
작업·worker·증거·사용량·승인 요청을 표시합니다. 서버는 Python 3.9+가 필요하며,
`dashboard -Snapshot -Json`은 PowerShell만으로 조회합니다. [현황판 사용법과 지표](docs/dashboard.md).

작업을 이어갈 때는 [현재 상태와 다음 작업](docs/current_state.md)을 먼저 읽으세요. AI 코딩 도구용 작업 규칙은 [CLAUDE.md](CLAUDE.md)에 있습니다.
과거 대화·결정·검증 기록은 [docs/archive/](docs/archive/)에 보관합니다.

## 범위

- 재사용 가능한 PowerShell 및 POSIX shell 엔진
- 대상 프로젝트 설정과 관리자 프롬프트 템플릿
- 작업 큐, Codex CLI 실행, 재시도 및 재개
- 로컬 Git gate, GitHub PR 및 보호 규칙
- 개발 환경, 서비스, CI, 릴리스 및 보안 설정 생성
- 격리된 임시 저장소를 사용하는 Harness smoke 테스트

전체 기능과 각 구현 파일은 [기능 목록](docs/feature_inventory.md)에 있습니다.
알려진 제한과 개선 과제는 [현재 상태](docs/current_state.md)에 있습니다.

## 구조

| 경로 | 용도 |
| --- | --- |
| scripts/ | 실행 스크립트, 공통 함수, smoke 테스트 |
| dashboard/ | 로컬 조회 현황판 HTML·CSS·JavaScript |
| configs/ | 정책과 프로젝트 프로필 템플릿 |
| project/prompts/ | 관리자 역할과 seed 계획 형식 |
| githooks/ | 이식용 Git hook 템플릿 |
| .githooks/ | `install_git_hooks.ps1`이 설치하는 hook 위치 (Git 제외, 저장소에 추적하지 않음) |
| assignments/ | 작업 큐 설명; 실행 시 담당자별 큐 생성 |
| reports/ | 결과 및 재시도 프롬프트 템플릿 |
| docs/ | 사용법, 이식 가이드, 기능 목록 |

## 현재 설정

이 저장소에는 활성 대상 프로젝트 프로필 `project/configs/project_profile.json`이 없습니다.
공통 템플릿 `configs/project_profile.template.json`은 유지합니다.
대상 프로필과 담당자 구성을 정하기 전까지 운영 preflight와 cycle은 준비 완료 상태가 아닙니다.
대상 프로필 없이 실행하는 자체 회귀 테스트는 아래 명령으로 제공합니다.
기존 문서의 `harness/scripts/...` 명령은 대상 저장소 아래에 `harness/`를 배치한 구조를 기준으로 합니다.
핵심 PowerShell 및 개별 검증·cycle·retry shell은 독립·이식 배치를 지원합니다. [Shell 명령 계약](docs/shell_commands.md)에서 프로필 기반 실행, preview, 잘못된 인자·경로·재귀 거부와 전환 방법을 확인하세요. 플랫폼 제한은 [배치 지원](docs/layout_support.md)에 있습니다.

Windows PowerShell 5.1/7·CMD·Git Bash와 WSL2 Ubuntu의 native PowerShell/Bash 추가 검증은 [플랫폼별 결과](docs/archive/verification_platforms_2026-10-15.md)에 있습니다. 실제 환경·파일시스템·실행별 통과 수를 구분합니다.

## 개발 시 확인

Provider 실행·결과·사용량은 [버전이 있는 계약](docs/provider_contract.md)으로 분리했습니다. Codex와 [Claude adapter](docs/claude_adapter.md)를 지원합니다. 실행 성공과 작업 검증 성공을 구분하고, 미지원 provider나 실패 이벤트를 성공으로 대체하지 않습니다. 실제 유료 호출 없이 로컬 fake 실행기로 검증합니다.

단일 진입점은 `pwsh -NoProfile -File scripts/harness.ps1 help`입니다.
`init/doctor/run/status/resume/usage/test`를 지원하며 기존 스크립트도 유지합니다.
[CLI 사용법](docs/cli.md)에서 부작용 없는 `-Preview`, 재개 조회와 실행의 구분, JSON 응답과 종료 코드를 확인할 수 있습니다.

```powershell
pwsh -NoProfile -File scripts/test_harness.ps1
```

PowerShell 구문·JSON 검사와 격리된 Git 저장소의 안전성 회귀 테스트를 실행합니다.
실제 AI나 GitHub API를 호출하지 않으며 결과는 `.test-output/<run-id>/results.json`에 남깁니다.
구문 검사만 실행하려면 `-SyntaxOnly`를 사용합니다.
Windows PowerShell 5.1에서는 필요 시 현재 프로세스에만 적용되는 `-ExecutionPolicy Bypass`로 실행합니다.

첫 개선 묶음은 승인 범위 검사, intake 민감정보 복사 차단, 소유권 잠금과 원자적 파일 저장입니다.
기존 설치의 변경 사항과 남은 작업은 [개선 진행표](docs/improvement_backlog.md)에 있습니다.

두 번째 개선 묶음은 worker 실행 전 기록·별도 잠금과 큐 전환 journal입니다.
부모 종료 후 중복 실행을 막고 중단된 큐 이동을 조정합니다. 복구 명령과 제한은 [복구 설계](docs/recovery_design.md)에 있습니다.

세 번째 묶음은 독립·이식 경로 통일, worktree hook, Codex CLI 옵션 갱신과 실행별 사용량/다음 실행 제한입니다. [사용량·정책·조회 명령](docs/execution_usage.md)을 제공합니다. 실제 구독 잔여량이나 청구 금액을 추정하지 않습니다.

네 번째 묶음은 [실행 증거 기반 성공 판정](docs/assignment_evidence.md)입니다. 작업 완료 시 검증 명령을 실제로 실행하고 코드·Git 상태·로그·worker 종료를 연결합니다. 증거 없는 기존 pass는 미검증으로 분류하며 `-Revalidate`로 다시 검증할 수 있습니다. [검증 기록](docs/archive/verification_evidence_2026-10-15.md)을 제공합니다.

PowerShell에서 프리셋 목록을 확인할 수 있습니다.

```powershell
pwsh -NoProfile -File scripts/init_project_adapter.ps1 -ListPresets
```

POSIX shell, Git, rsync, PowerShell이 준비된 환경에서는 아래 smoke 테스트가
별도 임시 저장소를 만들고 프로필을 초기화합니다.

```sh
sh scripts/run_portable_smoke.sh
sh scripts/run_operational_smoke.sh
sh scripts/run_git_hook_smoke.sh
sh scripts/run_pr_control_smoke.sh
sh scripts/run_github_policy_smoke.sh
sh scripts/run_platform_engineering_smoke.sh
sh scripts/run_security_quality_smoke.sh
```

각 테스트의 조건과 범위는 [스크립트 설명](scripts/README.md)을 참고하세요.
대상 프로젝트에 적용하는 절차는 [이식 가이드](docs/PORTING.md)에 있습니다.
