# 스터디룸 예약 API 요구사항

## 목표

회원이 스터디룸을 조회하고 시간 단위로 예약·취소하는 REST API를 만든다. 같은 룸·같은 시간에 동시에 요청이 몰려도 예약은 하나만 성공해야 한다. 관리자는 룸을 관리한다.

## 기술 기준

- Java 21, Spring Boot 4.1, Gradle(Groovy) wrapper, 기본 패키지 `io.github.cjsan30.reserveroom`
- PostgreSQL. 스키마는 Flyway 마이그레이션(`src/main/resources/db/migration`)으로만 바꾼다. JPA `ddl-auto`는 `validate`
- 통합 테스트는 Testcontainers PostgreSQL을 쓴다(`TestcontainersConfiguration` 재사용). Docker가 실행 중이어야 한다
- 인증은 JWT(HS256) Bearer 토큰. 비밀번호는 BCrypt로 저장
- 실행 환경 값은 환경 변수로 받는다: `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `JWT_SECRET`. 테스트에는 테스트 전용 기본값을 둔다
- 시간은 `Asia/Seoul` 기준 `LocalDateTime`(ISO-8601, 예: `2026-11-02T10:00:00`)으로 주고받는다

## 공통 응답 규칙

- 오류 응답 본문: `{"code": "<UPPER_SNAKE>", "message": "<사람이 읽는 설명>"}`
- 상태 코드: 입력 검증 실패 400, 인증 없음·토큰 오류 401, 권한 없음 403, 없는 자원 404, 예약 충돌·중복 가입 409
- 성공 응답은 JSON. 생성은 201과 생성된 자원 본문

## 기능

### 1. 회원

| 메서드 | 경로 | 권한 | 설명 |
| --- | --- | --- | --- |
| POST | `/api/auth/signup` | 누구나 | `{email, password, name}`. 이메일 형식, 비밀번호 8자 이상, 이름 필수. 이미 있는 이메일이면 409 `DUPLICATE_EMAIL` |
| POST | `/api/auth/login` | 누구나 | `{email, password}` → `{accessToken, tokenType: "Bearer", expiresIn}`. 틀리면 401 `INVALID_CREDENTIALS` |
| GET | `/api/members/me` | 회원 | 내 정보 `{id, email, name, role}` |

- 역할은 `USER`, `ADMIN`. 가입하면 `USER`
- 관리자 계정은 Flyway 마이그레이션으로 1개 만든다(이메일 `admin@reserve-room.local`). 비밀번호는 아래 **미리 계산한 BCrypt 해시 값을 그대로** 넣는다. 마이그레이션에 평문 비밀번호를 쓰거나 DB 함수(`pgcrypto` 등)로 해시를 만들지 않는다
  - 해시: `$2a$10$.XYFcD3EDXz7b93GEy8ZO.cc45G531jcGFCV51NoKW2QfAwIxLe1S` (개발 전용 비밀번호 `admin-dev-password`를 Spring Security `BCrypt`, cost 10으로 만든 값. 평문은 `docs/env_manifest.md`에만 있음)

### 2. 스터디룸

| 메서드 | 경로 | 권한 | 설명 |
| --- | --- | --- | --- |
| GET | `/api/rooms` | 회원 | 활성 룸 목록 `{id, name, capacity, location}` |
| POST | `/api/rooms` | 관리자 | 룸 생성. `name` 필수·중복 불가(409 `DUPLICATE_ROOM_NAME`), `capacity` 1~20 |
| PATCH | `/api/rooms/{id}` | 관리자 | 이름·수용 인원·위치 수정 |
| DELETE | `/api/rooms/{id}` | 관리자 | 비활성화(실제 삭제 아님). 이후 새 예약 불가, 목록에서 제외 |

### 3. 예약

| 메서드 | 경로 | 권한 | 설명 |
| --- | --- | --- | --- |
| POST | `/api/reservations` | 회원 | `{roomId, startAt, endAt}`로 예약 생성 → 201 `{id, roomId, startAt, endAt, status}` |
| DELETE | `/api/reservations/{id}` | 본인 | 취소. 상태를 `CANCELED`로 바꾼다. 시작 시각이 지났으면 409 `RESERVATION_ALREADY_STARTED`. 남의 예약이면 403 |
| GET | `/api/reservations/me` | 회원 | 내 예약 목록(시작 시각 오름차순) |
| GET | `/api/rooms/{id}/availability?date=YYYY-MM-DD` | 회원 | 그 날짜 09:00~22:00의 30분 칸별 예약 가능 여부 |

예약 규칙:

1. 시작·종료는 30분 단위(`:00`, `:30`), 길이는 30분 이상 4시간 이하
2. 운영 시간 09:00~22:00 안에서만, 같은 날짜 안에서만
3. 과거 시각은 예약 불가
4. 같은 룸에서 `CONFIRMED` 예약과 시간이 겹치면 409 `RESERVATION_CONFLICT`. 구간은 시작 포함·종료 미포함(10:00~11:00과 11:00~12:00은 겹치지 않음)
5. 같은 회원은 다른 룸이라도 시간이 겹치는 예약을 동시에 가질 수 없다(409 `MEMBER_TIME_CONFLICT`)
6. 비활성 룸이나 없는 룸이면 404 `ROOM_NOT_FOUND`

### 4. 동시성

- 같은 룸·겹치는 시간에 대한 예약 요청이 동시에 여러 개 들어와도 정확히 하나만 성공하고 나머지는 409여야 한다
- 애플리케이션 코드의 사전 조회만으로는 부족하다. DB 수준에서 보장한다(예: PostgreSQL `btree_gist` 확장과 exclusion constraint, 또는 행 잠금). 방식은 구현자가 정하되 이유를 코드 주석에 남긴다
- 병렬 요청 테스트로 증명한다(예: 10개 스레드가 같은 시간 예약 → 성공 1, 충돌 9)

## 범위 밖

- 실제 호스팅·배포, 결제, 이메일 알림, 프런트엔드
- 토큰 재발급(refresh token), 비밀번호 찾기

## 완료 기준

- 위 기능마다 Testcontainers 통합 테스트가 있고 `./gradlew test`가 통과한다
- 동시성 테스트가 성공 1·충돌 나머지를 확인한다
- 스키마 변경은 모두 Flyway 마이그레이션 파일로 남아 있다
