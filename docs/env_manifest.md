# Environment Manifest

## Policy

- Do not commit real private tokens, passwords, API keys, or personal credentials.
- Record required environment variable names and safe local/mock setup here.

## Environment Variables

| name | purpose | required_later | `.env.example` value |
| --- | --- | --- | --- |
| DB_URL | PostgreSQL JDBC URL | yes (local run) | `jdbc:postgresql://localhost:5432/reserve_room` |
| DB_USERNAME | PostgreSQL user | yes (local run) | `reserve_room` |
| DB_PASSWORD | PostgreSQL password | yes (local run) | `change-me` |
| JWT_SECRET | HS256 signing key, at least 32 bytes | yes (local run) | `change-me-to-a-32-byte-or-longer-secret` |

Tests do not need these: Testcontainers provides PostgreSQL and test resources provide a test-only JWT secret.

## Prepared Data

- Seed admin account created by a Flyway migration: `admin@reserve-room.local`. Development-only password `admin-dev-password` (stored only as a BCrypt hash in the migration). Change or remove before any real deployment.

## External Dependencies

- Docker (Testcontainers PostgreSQL for tests)

## Secrets And Access

- JWT_SECRET
- DB_PASSWORD
