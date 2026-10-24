# Assignment Seed Plan

## Meta

- plan_id: reserve-room-v1
- summary: Study room reservation API in six serial assignments
- dispatch_mode: serial

## Assignment

- owner: agent-data
- title: schema-foundation
- work_area: src/main/resources

### Task

Create the database foundation described in docs/requirements.md. Add Flyway migration V1 with tables for members (id, email unique, password_hash, name, role, created_at), rooms (id, name unique, capacity, location, active, created_at) and reservations (id, member_id, room_id, start_at, end_at, status, created_at, canceled_at) with foreign keys and sensible indexes. Add a second migration that inserts the seed admin account with a BCrypt hash of the development password listed in docs/env_manifest.md. Configure application.properties to read DB_URL, DB_USERNAME, DB_PASSWORD from the environment, set spring.jpa.hibernate.ddl-auto=validate and the Asia/Seoul JDBC time zone. Add JPA entities for the three tables so validation passes.

### Acceptance

- ./gradlew test passes with Testcontainers PostgreSQL and the migrations applied
- an integration test confirms the seed admin row exists with role ADMIN and a BCrypt hash, not a plain password

### Notes

Do not implement endpoints yet. Keep later concurrency work possible: reservations must store start_at and end_at as timestamps.

## Assignment

- owner: agent-runtime
- title: auth-jwt
- work_area: src/main/java

### Task

Implement sign-up, login and the current-member endpoint from docs/requirements.md section 1. Use Spring Security with stateless JWT (HS256) Bearer authentication; read the signing key from JWT_SECRET and provide a test-only default in src/test/resources. Passwords are BCrypt. Return the common error body for 400, 401, 403 and 409 (DUPLICATE_EMAIL, INVALID_CREDENTIALS), including for requests rejected by the security filter chain.

### Acceptance

- integration tests cover sign-up, duplicate e-mail 409, login success and failure, /api/members/me with and without a token, and an invalid token returning 401 with the common error body
- ./gradlew test passes

### Notes

Add a JWT library dependency in build.gradle if needed. The seed admin from the previous assignment must be able to log in.

## Assignment

- owner: agent-api
- title: rooms-api
- work_area: src/main/java

### Task

Implement the room endpoints from docs/requirements.md section 2: list active rooms for members, and create, update and deactivate for admins only. Enforce name uniqueness (409 DUPLICATE_ROOM_NAME) and capacity 1 to 20 (400).

### Acceptance

- integration tests cover member list, admin create, duplicate name 409, invalid capacity 400, member trying to create 403, update, and deactivation removing the room from the list
- ./gradlew test passes

### Notes

none

## Assignment

- owner: agent-domain
- title: reservation-rules
- work_area: src/main/java

### Task

Implement reservation create, cancel and my-reservations from docs/requirements.md section 3 with every reservation rule (30-minute units, 30 minutes to 4 hours, 09:00 to 22:00 on one date, no past times, half-open overlap with CONFIRMED reservations in the same room returns RESERVATION_CONFLICT, the same member cannot hold overlapping reservations in any room returns MEMBER_TIME_CONFLICT, inactive or missing room returns ROOM_NOT_FOUND, cancel only by the owner and only before start).

### Acceptance

- integration tests cover each rule, including the boundary case 10:00-11:00 followed by 11:00-12:00 succeeding
- cancel by another member returns 403 and cancel after start returns 409 RESERVATION_ALREADY_STARTED
- ./gradlew test passes

### Notes

Make the current time injectable (for example a Clock bean) so time-dependent rules are testable.

## Assignment

- owner: agent-data
- title: concurrency-guarantee
- work_area: src/main/resources

### Task

Guarantee at the database level that two CONFIRMED reservations for the same room can never overlap, even under concurrent requests, as required by docs/requirements.md section 4. Add a new Flyway migration (for example the btree_gist extension and an exclusion constraint on room and time range for CONFIRMED rows, or another database-enforced approach) and translate the database violation into 409 RESERVATION_CONFLICT. Explain the chosen approach in a code comment.

### Acceptance

- a concurrency integration test sends at least 10 simultaneous overlapping reservation requests for one room and asserts exactly one success and the rest 409
- ./gradlew test passes, including all earlier tests

### Notes

Do not edit existing migration files; add a new one.

## Assignment

- owner: agent-api
- title: availability-api
- work_area: src/main/java

### Task

Implement GET /api/rooms/{id}/availability?date=YYYY-MM-DD from docs/requirements.md section 3: return each 30-minute slot between 09:00 and 22:00 for that date with whether it is available, considering CONFIRMED reservations only. Make sure every error path in the API returns the common error body.

### Acceptance

- integration tests cover a day with no reservations, a day with a reservation blocking its slots, a canceled reservation not blocking slots, an invalid date 400 and an unknown room 404
- ./gradlew test passes

### Notes

none
