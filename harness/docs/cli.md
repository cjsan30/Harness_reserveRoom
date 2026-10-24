# 단일 운영 CLI

2026-10-15 추가. `scripts/harness.ps1`은 기존 스크립트의 공개 진입점을 묶습니다. 기존 명령을 유지하며 큐·worker·usage·증거·Git 승격 정책은 해당 구현에 위임합니다. 이후 [provider 계약](provider_contract.md)에 Codex와 [Claude adapter](claude_adapter.md)를 연결했습니다. provider는 대상 프로필의 worker_provider로 선택합니다.

독립 배치 또는 개발 checkout에서:

```powershell
pwsh -NoProfile -File scripts/harness.ps1 help
pwsh -NoProfile -File scripts/harness.ps1 test -SyntaxOnly -Json
pwsh -NoProfile -File scripts/harness.ps1 test
```

이식 배치에서는 `harness/scripts/harness.ps1`을 사용합니다. `-Root <저장소 경로>`를 지정하면 그 저장소에 설치된 Harness의 스크립트를 호출합니다. `-Root` 생략 시 기존 `CODEX_HARNESS_ROOT`/스크립트 위치 기반 탐색을 따릅니다. 대상에는 Harness가 설치되어 있어야 하며 이 명령이 엔진을 복사하거나 내려받지는 않습니다.

## 명령과 효과

| 명령 | 기존 진입점 | 효과 |
| --- | --- | --- |
| `init` | init_project_adapter | 프로필·설명 문서·ignore 등 생성. `-Force`, `-ListPresets`, 프로젝트/언어/요구사항 옵션 지원 |
| `doctor` | run_harness_preflight | 기존 사전 검사, 쓰기 가능 검사·진단 디렉터리·보고서 생성. hook 설치/활성화는 하지 않음 |
| `run -PlanFile <file>` | run_seed_handoff | 기본은 실제 seed 실행. hook 설치·preflight·작업자·기존 자동 승격 절차 포함 |
| `resume -PlanFile <file>` | get_seed_handoff_resume | 재개 상태와 보고서 생성. 작업자 실행이나 강제 복구 없음 |
| `resume -PlanFile <file> -Execute` | run_seed_handoff -Resume | 기존 안전한 재개 경로 실행. 불명확한 worker를 강제로 해제하지 않음 |
| `status` | get_harness_status | 상태 JSON/Markdown 갱신 |
| `usage` | get_execution_usage | 기록된 사용량 조회; 읽는 동안 budget lease 사용 |
| `test` | test_harness | 자체 회귀. `-SyntaxOnly`면 구문/JSON만 검사 |

`run`과 `resume`는 대상 루트 내부의 명시적 `-PlanFile`이 필요합니다. 최신 파일을 자동 선택하지 않습니다. `-RequirementsFile`도 루트 내부 파일이어야 합니다. 이 검사는 경로 정규화 기반이며 임의 junction/symlink에 대한 OS sandbox를 제공하는 것은 아닙니다.

`init` 옵션: `-ProjectName`, `-Requirements`, `-RequirementsFile`, `-Language`, `-Runtime`, `-Framework`, `-Ide`, `-ApplicationType`, `-Force`, `-ListPresets`. 대화식 초기화와 기타 고급 옵션은 기존 스크립트를 직접 사용합니다. 요구사항에는 credential을 넣지 마세요.

`run` 및 `resume -Execute` 옵션: `-Model`, `-MaxWorkerAttempts`, `-StaleAfterSeconds`, `-Ephemeral`, `-DryRun`, `-PreflightOnly`, `-StopOnWorkerFailure`, `-SkipAutoAdvanceGit`. 양의 정수가 아닌 제한, 중복·알 수 없는 옵션, `-DryRun`과 `-PreflightOnly` 동시 지정은 거부합니다. 보고서만 조회하는 `resume`에 worker 실행 옵션을 붙여도 거부합니다.

## 미리보기

```powershell
pwsh -NoProfile -File scripts/harness.ps1 run -PlanFile plans/seed.md -Preview -Json
pwsh -NoProfile -File scripts/harness.ps1 resume -PlanFile plans/seed.md -Json
```

`-Preview`는 경로·인수를 확인한 호출 계획만 반환하고 대상 스크립트를 실행하지 않습니다. 프로필·hook·보고서를 만들지 않으며 AI를 호출하지 않습니다. 실제 실행 준비 완료를 보장하는 preflight는 아닙니다.

`-DryRun`은 기존 workflow의 옵션입니다. AI를 실행하지 않아도 hook 설치와 preview 보고서 생성이 가능합니다. 파일 변경 없는 확인에는 `-Preview`를 사용하세요. `run`은 `-Preview`/`-DryRun`/`-PreflightOnly` 없이 호출하면 실제 실행합니다.

## 결과와 종료 코드

`-Json`은 한 개의 v1 응답 객체를 출력합니다.

| 필드 | 의미 |
| --- | --- |
| `schema_version` | 1 |
| `command` | 선택한 CLI 명령 |
| `execution_status` | succeeded / failed / preview |
| `exit_code` | CLI 코드: 0 호출 성공/미리보기, 1 실행·대상 준비 오류, 2 CLI 문법 오류 |
| `child_exit_code` | 실제 하위 명령의 코드. 호출 전 오류/preview는 null |
| `data` | status/usage/resume 조회의 구조화 결과 또는 preview 호출 계획 |
| `output` | 기타 명령 출력과 진단 |

조회 명령의 `execution_status: succeeded`는 조회가 성공했다는 뜻입니다. 프로젝트 준비 여부와 검증 성공은 `data.status`, `data.assignments` 등 실제 결과로 판단합니다. 하위 명령의 exit 7 등은 CLI exit 1로 정규화하면서 `child_exit_code`에 보존합니다. 기존 스크립트를 직접 호출할 때의 종료 코드는 바꾸지 않습니다.

허용된 명령/옵션만 해석하며 동적으로 입력을 코드로 평가하지 않습니다. 하위 프로세스에 UTF-8 JSON payload와 고정된 encoded bootstrap을 전달하고 PowerShell splatting으로 인수를 바인딩합니다. 따옴표·개행·shell 메타문자도 값으로 전달합니다. 자식에서 대상 루트를 지정하고 상속된 Git workspace override를 해제하며 부모 환경은 유지합니다. 대상 엔진 파일 자체는 신뢰하는 로컬 코드입니다.

현재 결과는 하위 실행이 끝난 뒤 출력됩니다. 실시간 스트리밍, 긴 문자열 payload의 OS 명령행 길이 제한 해소, 모든 기존 스크립트 옵션의 노출은 후속 과제입니다. 긴 요구사항에는 `-RequirementsFile`을 사용하세요. CLI는 main 승인/merge, provider 자동 전환, 실행 중 timeout을 추가하지 않습니다.

## 검증

`test_harness_cli.ps1`에 유닛·통합·보안 범주를 명시한 회귀가 있으며 전체 `test_harness.ps1`에도 포함됩니다. 실제 init/status/preflight와 fake seed backend를 사용하고 AI나 원격 서비스를 호출하지 않습니다. 상세는 [CLI 검증 기록](archive/verification_cli_2026-10-15.md)을 참고하세요.
# Dashboard extension (2026-10-15)

`harness.ps1 dashboard` starts a read-only loopback web monitor (Python 3.9+).
Server options: `-Port 0..65535`, `-RefreshSeconds 5..300`, `-PythonExecutable`, `-NoOpen`.
`-Snapshot -Json` instead returns one structured snapshot without Python or writes.
`-Preview -Json` works for either mode. Server mode streams its URL and does not accept
`-Json` without `-Preview`; snapshot mode refuses server-only options. Ctrl+C stops the server.
See [data semantics, commands and security limits](dashboard.md).

