CREATE TABLE members (
    id            BIGSERIAL    PRIMARY KEY,
    email         VARCHAR(255) NOT NULL,
    password_hash VARCHAR(100) NOT NULL,
    name          VARCHAR(100) NOT NULL,
    role          VARCHAR(20)  NOT NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_members_email UNIQUE (email),
    CONSTRAINT ck_members_role CHECK (role IN ('USER', 'ADMIN'))
);

CREATE TABLE rooms (
    id         BIGSERIAL    PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    capacity   INTEGER      NOT NULL,
    location   VARCHAR(255),
    active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_rooms_name UNIQUE (name),
    CONSTRAINT ck_rooms_capacity CHECK (capacity BETWEEN 1 AND 20)
);

CREATE TABLE reservations (
    id          BIGSERIAL   PRIMARY KEY,
    member_id   BIGINT      NOT NULL,
    room_id     BIGINT      NOT NULL,
    start_at    TIMESTAMP   NOT NULL,
    end_at      TIMESTAMP   NOT NULL,
    status      VARCHAR(20) NOT NULL,
    created_at  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    canceled_at TIMESTAMP,
    CONSTRAINT fk_reservations_member FOREIGN KEY (member_id) REFERENCES members (id),
    CONSTRAINT fk_reservations_room FOREIGN KEY (room_id) REFERENCES rooms (id),
    CONSTRAINT ck_reservations_status CHECK (status IN ('CONFIRMED', 'CANCELED')),
    CONSTRAINT ck_reservations_period CHECK (start_at < end_at)
);

-- 룸별 가용성 조회와 겹침 검사
CREATE INDEX idx_reservations_room_start ON reservations (room_id, start_at);
-- 내 예약 목록(시작 시각 오름차순)과 회원 시간 겹침 검사
CREATE INDEX idx_reservations_member_start ON reservations (member_id, start_at);
