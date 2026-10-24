# Shell 명령 계약과 전환

2026-10-15 여덟 번째 구현. 개별 검증·전체 사이클·retry의 6개 shell 진입점을 같은 PowerShell 엔진에 연결했습니다. 변경 근거는 검증 기록에 있습니다.

## 호출과 옵션

아래는 독립 배치 기준입니다. 이식 배치는 `scripts/` 대신 `harness/scripts/`를 사용합니다. 호출한 스크립트가 설치된 프로젝트에서 실행하므로 호출자의 현재 디렉터리에 의존하지 않습니다.

```sh
sh scripts/run_build.sh
sh scripts/run_unit.sh --preview
sh scripts/run_unit.sh
sh scripts/run_integration.sh
sh scripts/run_benchmark_smoke.sh
sh scripts/run_harness_cycle.sh --skip-retry-prompt
sh scripts/generate_retry_prompt.sh
sh scripts/run_unit.sh --help
```

| 진입점 | 허용 옵션 | 실행 내용 |
| --- | --- | --- |
| run_build/unit/integration/benchmark_smoke.sh | `--preview` 또는 `-Preview` | 해당 profile.commands 필드 |
| run_harness_cycle.sh | `--skip-retry-prompt` 또는 `-SkipRetryPrompt` | 기존 preflight·잠금·순차 검증·보고서 |
| generate_retry_prompt.sh | 없음 | PowerShell retry 생성과 프로필 담당자별 validation |
| 위 모든 진입점 | `--help` 단독 | 런타임 탐색 없이 도움말 출력 |

옵션은 한 번만 사용하며 임의의 추가 인자는 종료 코드 2로 거부합니다. 프로젝트 도구의 인자는 프로필 명령에 적습니다. 과거 wrapper는 이 인자를 무시했으므로 이전에 전달해 온 옵션이 실제 적용됐다고 가정하지 마세요.

개별 단계는 도구의 종료 코드를 그대로 반환합니다(예: 37). 설정·런타임·재귀 오류는 1입니다. 전체 사이클의 실패는 기존처럼 1이며 개별 도구의 코드를 반환하는 계약은 아닙니다. 단일 CLI `harness.ps1`의 0/1/2 계약도 유지합니다.

OS와 호출 shell의 종료 상태 표현 범위는 그대로 적용됩니다. Windows의 임의 32비트 상태값까지 POSIX shell에서 동일하게 보존한다고 보장하지 않습니다.

`--preview`는 대상 루트·정규화된 명령·`executes:false`를 JSON으로 출력하고 검증 도구를 실행하지 않습니다. shell 런타임의 캐시 환경 준비는 일어날 수 있습니다. 개별 단계는 cycle 전체 gate나 완료 증거 생성을 대체하지 않습니다.

## 프로필 및 경로

독립 배치는 `project/configs/project_profile.json`, 이식 배치는 `harness/project/configs/project_profile.json`의 `commands.build/unit/integration/benchmark_smoke`를 사용합니다. 프로필이 없거나 명령이 비어 있거나 템플릿/객체이면 실패합니다. 성공만 출력하는 no-op 및 알려진 실패 은폐 구문도 거부합니다.

Windows의 프로필 명령은 `cmd.exe`로 실행됩니다. 상속된 환경에 `NoDefaultCurrentDirectoryInExePath=1`이 있으면 `cmd`는 현재 폴더의 실행 파일을 경로 없이 찾지 않으므로, 저장소 안의 wrapper는 `.\gradlew.bat`, `.\mvnw.cmd`처럼 경로를 명시하세요. adapter의 Java 프리셋은 wrapper가 있으면 이 형식으로 생성합니다.

make 사용자는 `make build`, `make unit` 등의 실제 명령을 프로필에 명시하세요. 기본 make fallback은 제거했습니다. bare `make`로 시작할 때는 실행 가능한 `make`, 이어 `mingw32-make`를 찾아 절대 경로로 고정합니다.

`CODEX_HARNESS_ROOT`와 `CODEX_GIT_WORKSPACE_ROOT`가 설정되어 있다면 호출한 엔트리의 설치 프로젝트와 같아야 합니다. 다른 저장소를 가리키는 상속 환경은 실행 전에 거부합니다. 의도한 worktree 안에 설치된 엔트리와 그 경로에 맞는 환경을 사용하세요. 공유 엔진을 다른 프로젝트로 조용히 재지정하지 않습니다.

프로필 명령은 Harness wrapper가 아닌 실제 도구를 지정해야 합니다. wrapper → 프로필 명령 → 같은 wrapper/cycle 재귀는 `HARNESS_VALIDATION_ACTIVE`로 차단합니다. Makefile이 다시 wrapper를 부르는 구성도 수정해야 합니다. 이 환경 변수는 실수 방지 장치이며 보안 sandbox는 아닙니다.

## 실행 환경과 한계

- 모든 6개 wrapper에는 PowerShell이 필요합니다. `CODEX_HARNESS_PWSH`가 잘못되면 다른 실행기로 대체하지 않습니다. Windows 역슬래시 경로도 Git shell 경로로 변환합니다.
- Windows Git shell → PowerShell → cmd.exe 경로에서 한글·공백·대괄호·`&` 경로, 따옴표로 감싼 공백·`&`·`|` 인자, 절대 실행 파일 경로를 검사합니다. MSYS 중복 인수 변환을 bridge 프로세스에서 차단합니다.
- Windows 명령 문자열은 cmd.exe, POSIX는 기존 bash/sh 규칙을 따릅니다. 모든 OS에서 같은 문자열이 동일한 뜻이라는 보장은 없습니다. 구조화된 executable/argv 형식으로 바꾼 것은 아닙니다.
- 프로필 명령은 신뢰하는 프로젝트 코드입니다. 임의 명령 문자열을 안전하게 만드는 보안 필터나 OS sandbox를 제공하지 않습니다.
- WSL에서는 native pwsh를 요구하고 명시적인 Windows `.exe` 런타임을 거부합니다. WSL2 Ubuntu 24.04의 native PowerShell/Bash 및 Windows 직접 호출·CMD·Git Bash는 플랫폼별 검증에 실제 결과를 남겼습니다. 원격 CI·별도 Linux 서버/배포판까지 포함한 검증은 아닙니다.
- `smoke_*.sh`, 설치·hook 등 다른 shell 유틸리티 전체를 이 bridge로 전환한 것은 아닙니다. 실행 중 timeout과 실시간 스트리밍도 후속 과제입니다.

## 자체 회귀

```powershell
pwsh -NoProfile -File scripts/test_harness_shell.ps1
pwsh -NoProfile -File scripts/test_harness_entrypoints.ps1
pwsh -NoProfile -File scripts/test_harness.ps1
```

Node.js와 Git POSIX shell을 사용해 `.test-output/<id>` 안에 실제 숫자 합계 CLI를 만들고 두 배치에 Harness를 설치합니다. 잘못된 입력, 단계 실패, 다른 cwd, 프로젝트 복사 후 실행, 프로필/환경/옵션 오류를 검사합니다. 전체 사이클 fixture는 기존 경로 테스트와 같은 CI 모드로 현재 브랜치 승인 감사만 생략하며, preflight·hook 설치·단계 순서·실패 중단은 실행합니다. 원본 프로젝트나 활성 프로필을 수정하지 않습니다.

entrypoint suite는 Windows에서 PowerShell/CMD/Bash 30개, Linux에서 native PowerShell/Bash 20개를 검사합니다. 전체 runner는 기존 shell fixture를 재사용합니다. shell suite의 `-CasePattern '*relocated*'`는 이동 사례 2개만 선택하며 결과는 전체 36개 통과와 구분해야 합니다. 일치하는 사례가 없으면 exit 1입니다.
