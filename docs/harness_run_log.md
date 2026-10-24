# Harness 실행 기록

이 저장소는 [Harness](https://github.com/cjsan30/Harness_) 엔진으로 AI(Claude Code) worker에게 작업을 맡겨 만드는 스터디룸 예약 API입니다. 이 문서는 실행할 때마다 무엇이 실패했고 원인이 무엇이었으며 어떻게 고쳤는지를 기록합니다.

- 엔진 버전: Harness_ `dev` `dd3b8f2` (2026-10-22)를 `harness/`로 복사 → 2026-10-25 `002046d`(F-01~F-11 수정)로 교체
- 환경: Windows 10, Windows PowerShell 5.1 + PowerShell 7.6, JDK 21 (Temurin), Docker 29.9, Claude Code 2.1.310 (구독)

## 0단계: 준비 (AI 호출 없음, 2026-10-24)

엔진 수정 대상은 엔진 저장소 [docs/field_findings.md](https://github.com/cjsan30/Harness_/blob/dev/docs/field_findings.md)에 F-01~F-11로 따로 관리합니다(3→F-01, 4→F-02, 5→F-03, 6→F-04·F-05, 7→F-06, 8→F-07, 9→F-08, 10→F-09, 11→F-10, 12→F-11).

| # | 무엇이 일어났나 | 원인 | 조치 | 구분 |
| --- | --- | --- | --- | --- |
| 1 | Spring Initializr 뼈대의 첫 `gradlew test`가 `ApplicationContext` 로딩 실패 | Docker Desktop이 꺼져 있어 Testcontainers가 PostgreSQL을 띄우지 못함 → Flyway·JPA 연쇄 실패 | Docker 실행 후 재실행, BUILD SUCCESSFUL | 환경 |
| 2 | 패키지·클래스 이름이 `reserve_rrom` | Initializr Artifact 입력 오타 | 첫 커밋 전에 `reserveroom`/`ReserveRoomApplication`/`reserve-room`으로 수정 | 입력 |
| 3 | Java 프리셋 명령이 `gradle build` | adapter가 Gradle wrapper가 아닌 전역 `gradle`을 가정 (이 PC에는 전역 Gradle 없음) | 프로필 명령을 wrapper로 지정 | **엔진 개선점** |
| 4 | owner 작업 영역이 `src/api`, `src/domain` 등 | adapter 기본값이 Java 표준 구조(`src/main/java`)와 다름 | 프로필에서 실제 경로로 수정 | **엔진 개선점** |
| 5 | `cmd`에서 `gradlew.bat`을 찾지 못함 | 실행 환경에 `NoDefaultCurrentDirectoryInExePath=1`이 있으면 `cmd`가 현재 폴더 실행 파일을 경로 없이 찾지 않음 | 명령을 `.\gradlew.bat`로 명시 | **엔진 개선점** |
| 6 | adapter가 기존 `.gitignore`를 유지해 하네스 규칙이 빠짐. 템플릿에도 `.githooks/`, `harness/assignments/*/.queue/`가 없음 | Spring이 만든 `.gitignore`가 이미 있으면 adapter는 건너뜀 | 템플릿 내용을 루트 파일에 덧붙이고 두 경로 추가 | **엔진 개선점** |
| 7 | `docs/requirements.md` 초안에 `$resolvedProjectName`이 그대로 들어감 | adapter의 문서 템플릿에서 변수가 치환되지 않음 | 요구사항 문서를 직접 작성 | **엔진 버그** |
| 8 | `AGENT.md`에 `replace-with-...` 자리표시자가 남았는데 preflight가 통과 | preflight가 루트 `AGENT.md`의 자리표시자를 검사하지 않음 | `AGENT.md` 직접 작성 | **엔진 개선점** |
| 9 | 첫 커밋(bootstrap)이 "작업 트리가 깨끗하지 않다"며 거부 | bootstrap이 `harness/reports/`를 전부 산출물로 보고 커밋 후보에서 빼서, 커밋돼야 할 템플릿 2개가 미추적으로 남음 | 두 템플릿을 미리 stage해 우회 (엔진 수정 예정) | **엔진 버그** |
| 10 | worker가 작업마다 문서 7개(약 650줄)를 읽도록 기본 설정됨 | adapter 기본 read 목록이 넓음 | 작업 worker는 `AGENT.md`, 요구사항, 환경 문서 3개만 읽게 줄임 (토큰 절약) | 설계 결정 |
| 11 | (실행 전 코드 검토) 작업 브랜치가 항상 `main`에서 출발 | 직렬 계획에서 앞 작업 결과는 `dev`에만 있어 다음 작업이 모름 → 중복 구현·merge 충돌 예상 | 첫 유료 실행 전에 엔진에서 수정 예정 | **엔진 설계 문제** |
| 12 | (실행 전 코드 검토) 병합된 작업 브랜치·worktree가 정리되지 않음 | seed 흐름에 정리 단계 없음 | 엔진 개선 예정, 그 전까지 수동 정리 | **엔진 개선점** |

결과: bootstrap 검증 사이클(preflight, build, test, check, smoke) 통과 후 첫 커밋 `bd65174`.

## 0.5단계: 엔진 수정 후 교체 (2026-10-25)

- 엔진 저장소에서 위 엔진 항목(F-01~F-11)을 회귀 테스트와 함께 수정. 특히 F-10은 고치면서 더 근본적인 원인이 나옴: seed 흐름이 작업마다가 아니라 **모든 작업이 끝난 뒤 한꺼번에** `dev`로 승격하고 있어서, 출발점을 `dev`로 바꿔도 직렬 작업이 앞 결과를 못 봄 → 통과한 작업을 즉시 `dev`로 승격하도록 변경
- 이 저장소의 `harness/`를 새 엔진으로 교체(정책 상태 `harness/state/`와 프로젝트 설정 `harness/project/`는 유지)
- 정리: 더 이상 쓰지 않는 생성 문서 4개(`docs/subagent_plan.md`, `docs/subagent_first_prompts.md`, `docs/requirements_raw_links.md`, `docs/project_profile_generated.md`)를 Git 추적에서 빼고 로컬 전용 `local_notes/`로 이동. 프로필의 문서 목록도 정리

- 교체 커밋의 feature gate(전체 하네스 사이클)가 **실패**: unit 단계에서 Testcontainers가 Docker에 연결하지 못함(`DockerClientProviderStrategy`). Docker Desktop이 WSL 관련 오류로 엔진을 시작하지 못한 상태("unable to start")였음. 사용자가 Docker Desktop을 다시 띄워 복구. 하네스는 unit 실패에서 이후 단계를 실행하지 않고 gate를 실패로 기록(fail closed) → Docker 복구 후 재실행

## 1단계: AI worker 실행

(실행 후 기록)
