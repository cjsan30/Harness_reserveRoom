# Subagent Plan Template

## Purpose

Use this template to define subagent roles for a new project after copying the portable `harness/` directory.

## Read Order

Each worker should read:

1. `AGENT.md`
2. `docs/requirements.md`
3. `docs/subagent_plan.md`
4. `docs/subagent_first_prompts.md`
5. `harness/AGENT.md`
6. the owned folder's local `AGENT.md`, when present

## Git Rule

- live work must happen on a feature branch named `<owner>/<task>`
- workers do not work directly on `main`, `dev`, or `test/*`
- commits, pushes, and promotions follow `harness/configs/git_policy.md`

## Owner Map

Replace the examples below with the target repository's actual modules. Keep owner names aligned with `harness/project/configs/project_profile.json`.

### agent-runtime

- owned area: replace with runtime, app shell, CLI, server entrypoint, or app bootstrap folder
- responsibilities:
  - entrypoint behavior
  - configuration and startup flow
  - runtime-facing integration
- validation: replace with owner validation command

### agent-domain

- owned area: replace with core domain, business logic, parser, model, or service folder
- responsibilities:
  - core behavior
  - public interfaces used by other modules
  - edge-case handling
- validation: replace with owner validation command

### agent-data

- owned area: replace with database, storage, API client, repository, persistence, or state folder
- responsibilities:
  - data loading and saving
  - schema and serialization rules
  - data access contracts
- validation: replace with owner validation command

### agent-ui-or-interface

- owned area: replace with UI, API routes, command interface, or external boundary folder
- responsibilities:
  - user-facing or client-facing behavior
  - input validation and output shape
  - integration with runtime and domain owners
- validation: replace with owner validation command

### agent-tests

- owned area: `tests` or target test folders
- responsibilities:
  - unit tests
  - integration tests
  - regression fixtures
  - smoke or benchmark checks
- validation: replace with test validation command

### manager-main

- owned area: project-wide
- responsibilities:
  - requirement prioritization
  - public interface approval
  - integration acceptance
  - final delivery judgment

### manager-harness

- owned area: `harness`
- responsibilities:
  - preflight and full-cycle validation
  - retry prompt generation
  - assignment queue health
  - Git gate and hook health

## Integration Rules

- each worker stays in its owned area first
- public interface changes are approved by `manager-main`
- high-conflict shared files are integrated deliberately
- `agent-tests` adds coverage around behavior touched by other owners
- `manager-harness` changes harness mechanics, not product behavior

## Delivery Order

Replace this order with the target project's natural dependency order:

1. runtime or app shell
2. public interfaces
3. core behavior
4. data/storage or external integration
5. tests and fixtures
6. harness cycle and handoff validation