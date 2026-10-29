# Harness 실행 기록

이 저장소는 [Harness](https://github.com/cjsan30/Harness_) 엔진으로 AI(Claude Code) worker에게 작업을 맡겨 만드는 스터디룸 예약 API입니다. 이 문서는 실행할 때마다 무엇이 실패했고 원인이 무엇이었으며 어떻게 고쳤는지를 기록합니다.

- 엔진 버전: Harness_ `dev` `dd3b8f2` (2026-10-22)를 `harness/`로 복사 → 2026-10-25 `002046d`(F-01~F-11 수정) → 2026-10-27 `7651f7b`(F-13·F-15 수정)로 교체 → 2026-10-29 `d102fdd`(실패 원인 분류, 작업별 실패 메모, 환경 확인·복구, 알림, F-22·F-23 수정)
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

- 교체분을 `dev`에 merge할 때 "target branch worktree must be clean"으로 거부: `dev`(첫 커밋 시점)의 `.gitignore`에는 아직 `local_notes/` 규칙이 없어 로컬 전용 폴더가 미추적으로 잡힘. 로컬 전용 폴더는 브랜치와 무관하게 `.git/info/exclude`에도 등록해 해결(엔진 저장소에도 동일 적용)

## 1단계: AI worker 실행

### 1-1. 첫 유료 실행: 작업 1(schema-foundation)만 (2026-10-25 21:18)

- 실행: `run_seed_handoff.ps1`, 작업 1만 담은 계획, `-MaxWorkerAttempts 2 -StopOnWorkerFailure -SkipAutoAdvanceGit`(이유는 아래 #3), 모델은 CLI 기본값
- 결과: **실패**(2회 시도, 총 234초). 하네스가 두 시도 모두 provider 실패로 판정하고 계획을 중단

| # | 무엇이 일어났나 | 원인 | 조치 | 구분 |
| --- | --- | --- | --- | --- |
| 1 | worker가 `./gradlew.bat test`, 완료 보고 명령, `python`을 모두 거부당함(권한 거부 5건) | Claude Code는 **신뢰(trust) 확인을 받지 않은 폴더**에서 `.claude/settings.json`의 허용 규칙을 무시함. 하네스는 작업마다 새 worktree 폴더에서 실행 → 허용 7건이 무시되고 `--permission-prompts none`이라 전부 자동 거부 | 저장소 루트를 Claude Code에서 한 번 신뢰 처리(사용자 작업) 후 재실행 예정 | **환경·엔진 개선점** |
| 2 | 1차: 관리자 시드 마이그레이션에 BCrypt 해시 대신 자리표시자를 남김. 2차: 같은 worktree에서 1차 결과를 읽고 원인을 진단해 PostgreSQL `pgcrypto`의 `crypt()`로 마이그레이션 중 해시를 만들게 수정 | 해시를 만들 코드를 실행할 수 없었음(#1). 2차 수정은 평문 비밀번호가 마이그레이션에 들어가 "해시로만 저장" 요구와 어긋남 — **worker가 스스로 위험으로 보고** | 요구사항에 미리 계산한 해시를 제공하거나 생성 방법을 허용하도록 계획 보완 | 계획 |
| 3 | 첫 실행에서 `dev` 자동 반영을 켤 수 없었음 | 새 엔진이 `dev`에만 있어 기본 작업 폴더를 `dev`로 둬야 하는데, 반영 단계는 `dev`를 별도 worktree로 열려고 함 | 측정 목적이라 `-SkipAutoAdvanceGit`로 실행 | **엔진 개선점** |
| 4 | 하네스 사용량 기록이 두 시도 모두 `unknown` | 실패한 실행의 사용량은 0이 아니라 unknown으로 기록하는 규칙. Claude는 실패해도 실제 사용량을 보고함 | 실제 수치는 Claude 결과 이벤트에서 직접 계산(아래) | **엔진 개선점** |
| 5 | 1차 시도의 실행 로그가 없음 | worker 로그를 시도마다 같은 파일에 덮어씀 | 2차만 수치 확보 | **엔진 개선점** |
| 6 | 실행 후 `harness/assignments/agent-data/.transitions/*.json`이 미추적으로 남음 | 큐 전환 기록 경로가 ignore 템플릿에 없음 | 루트 `.gitignore`에 추가 | **엔진 개선점** |

사용량(2차 시도, Claude 결과 이벤트 기준):

| 항목 | 값 |
| --- | --- |
| Claude 실행 시간 / 턴 | 83.8초 / 23턴 (하네스 기준 87.5초) |
| 입력 토큰 | 679,211 (캐시 읽기 643,727 + 캐시 생성 35,460 + 일반 24) |
| 출력 토큰 | 6,283 (사고 2,210 포함) |
| API 환산 비용 | $0.54 (구독이라 청구는 없고 사용 한도에서 차감) |
| 도구 사용 | Read 13, Bash 5(전부 거부), Glob 2, Grep 1, Write 1 |

1차 시도는 115초였고 수치는 남지 않았음(#5). 두 시도 합계는 대략 API 환산 $1 안팎, 입력 약 130만 토큰(대부분 캐시 읽기)으로 추정.

후속 조치(2026-10-25): #2에 대해 요구사항에 미리 계산한 BCrypt 해시를 넣음(Spring Security `BCrypt`, cost 10으로 생성하고 맞는/틀린 비밀번호로 검증). #1은 사용자가 저장소 루트를 Claude Code에서 신뢰 처리.

- 요구사항 변경을 `dev`에 merge할 때 또 "target branch worktree must be clean": `dev` 시점 `.gitignore`에 새 `.transitions/` 규칙이 없어서(0.5단계와 같은 종류). `.git/info/exclude`에도 추가해 해결
- **운영 실수:** merge 실패 직후 이어서 실행된 정리 명령이 아직 merge되지 않은 작업 브랜치를 지움. 커밋(`b2bb621`)이 남아 있어 같은 커밋으로 즉시 복구했고, gate·승격 기록은 브랜치 이름과 커밋에 묶여 있어 그대로 유효. 이후 정리는 merge 성공과 `dev` 포함 여부를 확인한 뒤에만 실행
- 작업 1의 worktree는 갱신 전 `dev`에서 만들어져 새 요구사항(해시)을 모름 → worktree에서 `dev`를 merge해 갱신(1~2차 시도 코드는 유지). 하네스에는 재시도 전에 작업 브랜치를 최신 `dev`로 맞추는 기능이 없음(엔진 개선점)

### 1-2. 재실행 전 엔진 수정 (2026-10-27)

- 1-1의 #3(`dev` 자동 반영 불가)을 다시 확인해 보니 진단이 틀렸음: 하네스는 `dev`가 이미 열린 worktree(기본 작업 폴더 포함)를 그대로 재사용하므로 충돌은 없음. 진짜 위험은 그 폴더에 커밋하지 않은 변경이 있으면 **작업이 다 끝난 뒤** 반영 단계에서야 실패해 토큰이 낭비된다는 것 → 실행 시작 전에 검사해 바로 멈추도록 엔진 수정
- 1-1의 #4(실패 실행의 사용량 unknown)에 대해, Claude가 실패해도 보고한 사용량을 `reported_usage`로 따로 보존하도록 엔진 수정(성공 판정·예산 계산은 그대로)
- **gate가 끝나지 않는 문제 발견:** PC 재시작 후 다시 돌린 feature gate가 모든 단계(build·test·check·smoke)를 15:14에 성공했는데도 프로세스가 끝나지 않음. 원인은 Gradle wrapper가 처음 띄운 **Gradle daemon이 하네스의 출력 파이프를 물려받아** 유휴 종료(기본 3시간)까지 살아 있었던 것. `gradlew --stop`으로 daemon을 멈추자 gate가 즉시 완료되어 원인 확인. 10-25~26의 "feature gate 후 3시간 공백"도 같은 원인으로 보임(daemon이 이미 떠 있을 때는 재현되지 않아 그동안 드러나지 않음). Claude worker 안의 `./gradlew test`도 같은 이유로 멈출 수 있어 유료 실행 전에 수정 → `gradle.properties`에 `org.gradle.daemon=false`

### 1-3. 작업 1 재실행 시도 (2026-10-27 15:26)

- 실행: `-Resume`, `dev` 자동 반영 켬, 현황판 캡처 동시 진행
- 결과: **AI 호출 없이 24초 만에 중단**. 화면 메시지는 "cannot requeue assignment ... because the latest state is in_progress/pending"
- 원인: 프로필의 `max_attempts_per_assignment: 2`를 작업 1이 10-25에 이미 다 써서(신뢰 문제로 실패한 2회) 하네스가 세 번째 실행 예약을 거부함 — **비용 안전장치가 설계대로 동작**. 거부된 작업은 규칙대로 `in_progress`에 보존
- 문제: 예약 거부 사유가 화면에 나오지 않고, 재시도 루프가 이어서 재등록을 시도하다 실패한 메시지만 보여 원인 파악이 어려움(엔진 개선점)
- 해결: 엔진에서 실패 원인을 분류해 **구현 실패만** 작업당 시도로 세도록 변경(환경·권한·provider 문제는 시도를 쓰지 않고 멈추거나 복구). 예약 거부 메시지에 어떤 한도에 몇 회를 썼는지와 추가 승인 명령을 표시(엔진 `d2f418c`). 단, 10-25의 두 시도는 분류 기록이 없는 옛 엔진 실행이라 보수적으로 구현 시도로 셈 → 재개하려면 작업 1에 시도 1회 추가 승인 필요

## 2단계 준비: 엔진 교체와 환경 선언 (2026-10-29, AI 호출 없음)

- 엔진을 `d102fdd`로 교체(28개 파일, 엔진 `dev`와 blob 해시 일치 확인)
- 프로필에 `environment` 선언: JDK 21(없으면 설치 안내와 함께 멈춤), Docker(설치 여부는 `docker --version`, 동작은 `docker info`, 꺼져 있으면 Docker Desktop 자동 시작 후 최대 180초 대기, 없으면 설치 안내와 함께 멈춤). 하네스 자체 도구(git, Claude CLI)는 엔진이 항상 먼저 확인
- **실제 복구 실행에서 엔진 버그 발견(F-23):** Docker가 꺼진 상태에서 `harness.ps1 env -Repair`를 실행하자 Docker는 켜졌지만 명령이 7분 넘게 끝나지 않음. 하네스가 띄운 Docker Desktop이 하네스 출력 통로를 물려받아 잡고 있었음(10-27 Gradle daemon과 같은 종류). 실행 중에 같은 일이 생기면 run 전체가 멈췄을 문제 → 엔진에서 분리 실행 방식 수정(`bf8f066`) 후 Docker를 끄고 다시 실행: **7초 만에 Docker 시작, 명령 정상 종료, `environment: ready`**
