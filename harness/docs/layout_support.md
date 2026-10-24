# 독립 배치와 이식 배치

2026-10-15 구현. `RootDir`은 대상 프로젝트 루트, engine root는 Harness 코드 위치입니다.

| 구조 | 엔진 | 프로필 | 명령 접두어 |
| --- | --- | --- | --- |
| 독립 | `<repo>/scripts/harness_common.ps1` | `<repo>/project/configs/project_profile.json` | `scripts/` |
| 이식 | `<repo>/harness/scripts/harness_common.ps1` | `<repo>/harness/project/configs/project_profile.json` | `harness/scripts/` |

`harness_layout.ps1`이 엔진을 선택합니다. 두 위치에 엔진 marker가 동시에 있으면 모호하므로 거부합니다. 프로필·잠금·큐·보고서·worker 완료 명령·생성 CI/환경/릴리스 경로가 선택된 엔진 위치를 사용합니다. 기존 프로필의 `harness/` 경로는 알려진 Harness 필드에서 독립 배치 경로로 변환합니다. 일반 프로젝트 경로의 루트 탈출 검사는 그대로 유지하고 요구사항 본문은 변환하지 않습니다.

Git 초기화 전에는 이름이 `harness`인 엔진 폴더를 이식 배치로 간주합니다. 이름이 정확히 `harness`인 독립 폴더는 먼저 Git을 초기화하거나 `CODEX_HARNESS_ROOT`를 명시하세요. 임의의 중첩 디렉터리 이름/복수 엔진 자동 선택은 지원하지 않습니다.

Shell 진입점은 상속 환경으로 설치 위치를 재지정하지 않습니다. 따라서 이름이 `harness`인 독립 폴더에서 shell을 사용하려면 먼저 Git을 초기화해야 합니다. 위 환경 변수 우회는 PowerShell 직접 호출에 해당합니다.

## Hook 및 shell

`install_git_hooks.ps1`은 네 hook과 `harness-bootstrap.sh`를 함께 설치합니다. main checkout의 공통 Git 디렉터리를 통해 정책 루트를 찾아 isolated worktree에서도 동일 정책에 도달합니다. `core.hooksPath`는 공유 절대 경로를 유지합니다. 저장소 이동이나 Windows/WSL 전환 후에는 해당 환경에서 설치 명령을 다시 실행해야 합니다. 분리된 외부 Git 디렉터리(`--separate-git-dir`)는 현재 테스트/지원 범위가 아닙니다.

```powershell
pwsh -NoProfile -File scripts/install_git_hooks.ps1
pwsh -NoProfile -File scripts/run_harness_preflight.ps1
```

이식 배치에서는 `harness/scripts/`로 바꿉니다. 개별 검증 4개와 cycle/retry shell 모두 공통 PowerShell 엔진에 위임합니다. PowerShell과 구성된 프로필이 필요하며 기본 make fallback은 없습니다. `--preview`, 인자·환경 경계와 전환 방법은 [Shell 계약](shell_commands.md)을 따릅니다. 상속된 root/workspace가 설치 프로젝트와 다르면 실행을 거부합니다.

## 검증 범위

Windows PowerShell 5.1/7에서 한글·공백·대괄호 경로의 두 배치를 검사합니다. 초기화, 실제 Git의 main/worktree hook 거부, preflight, 프로필 기반 cycle, fake worker 완료 및 JSONL 사용량, CI/환경/릴리스 생성·감사를 포함합니다. fixture의 단계 명령은 `git --version`이며 제품의 실제 동작 검증을 뜻하지 않습니다.

Ubuntu CI 정의는 유지하지만 원격 실행 결과는 없습니다. 이후 Windows PS5/7·CMD·Git Bash, WSL2 Ubuntu 24.04의 native Linux 실행과 Windows→WSL→Windows hook 재설치 전환을 실제 검사했습니다. `/tmp`와 `/mnt/c`의 결과는 [플랫폼별 검증](archive/verification_platforms_2026-10-15.md)을 따릅니다. 별도 Linux 서버/다른 배포판 및 유료 AI는 범위 밖입니다. 생성 파일 감사도 GitHub Actions/Docker 실제 실행 성공과 구분합니다.

여덟 번째 묶음의 shell fixture는 실제 Node 숫자 합계 CLI를 만들고 두 배치의 검증·실패 중단과 프로젝트 복사 후 실행을 검사합니다. 이전 git 버전 fixture와 별도이며 [결과와 한계](archive/verification_shell_2026-10-15.md)에 기록합니다.

WSL DrvFS에서 PowerShell Copy-Item으로 읽기 전용 `.git/objects` 메타데이터를 복사할 때 권한 오류를 재현했습니다. 이동 fixture는 Git 데이터베이스를 local clone으로 복제하고 나머지 프로젝트 파일을 복사합니다. 복사 후 Git 작업에는 새 위치/OS에서 hook을 다시 설치해야 합니다.
