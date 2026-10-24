# reserve-room 작업 안내 (AI worker용)

## 프로젝트

스터디룸 예약 REST API. 요구사항 전체는 [docs/requirements.md](docs/requirements.md)에 있다. 이 문서와 요구사항이 다르면 요구사항을 따른다.

- Java 21, Spring Boot 4.1, Gradle(Groovy) wrapper
- 기본 패키지 `io.github.cjsan30.reserveroom`. 기능별 하위 패키지(`auth`, `member`, `room`, `reservation`, `common`)로 나눈다
- PostgreSQL + Flyway(`src/main/resources/db/migration/V<번호>__<설명>.sql`) + JPA(`ddl-auto=validate`)
- 테스트: JUnit 5 + Spring Boot Test + Testcontainers PostgreSQL. 기존 `TestcontainersConfiguration`을 `@Import`해서 쓴다

## 명령

- 테스트: `./gradlew test` (Docker 실행 필요)
- 빌드: `./gradlew build`

## 규칙

- 맡은 작업 범위만 바꾼다. 다른 작업이 만든 코드는 되돌리지 않는다
- 스키마 변경은 새 Flyway 파일로만 한다. 이미 있는 마이그레이션 파일은 고치지 않는다
- 비밀값(JWT 비밀키, DB 비밀번호)을 코드에 하드코딩하지 않는다. 환경 변수로 받고, 테스트용 기본값은 `src/test/resources`에 둔다
- 새 동작에는 반드시 통합 테스트를 붙인다. 테스트를 통과시키려고 검증을 지우거나 약하게 하지 않는다
- `harness/` 폴더는 수정하지 않는다. 작업 완료 보고는 프롬프트에 적힌 `complete_assignment.ps1` 명령으로만 한다
- 원격 push, 브랜치 삭제, 기록 재작성은 하지 않는다

## Harness

- profile: harness/project/configs/project_profile.json
- preflight: pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1
- full cycle: pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1
