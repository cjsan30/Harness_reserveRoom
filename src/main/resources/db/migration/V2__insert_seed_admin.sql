-- 개발용 관리자 계정. 미리 계산한 BCrypt(cost 10) 해시만 저장한다. 평문은 docs/env_manifest.md 참고
INSERT INTO members (email, password_hash, name, role)
VALUES ('admin@reserve-room.local',
        '$2a$10$.XYFcD3EDXz7b93GEy8ZO.cc45G531jcGFCV51NoKW2QfAwIxLe1S',
        '관리자',
        'ADMIN');
