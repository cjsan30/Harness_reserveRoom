# Retry Dispatch Policy

## Purpose

This document defines how manager-harness reads retry prompts, chooses the next owner, and escalates repeated failures.

## Baseline Rules

- redistribute one primary failure at a time
- `compile` failures outrank everything else
- `interface` failures are reviewed by `manager-main` before broad redistribution
- `logic` failures go to the most direct owner
- `missing-test` failures go to `agent-tests` first
- `environment` failures stay with `manager-harness` or `manager-main` before product agents
- owner `read` paths, `work_area`, and harness output paths must stay inside the repository root

## Dispatch Priority

1. `compile`
2. `interface`
3. `logic`
4. `missing-test`
5. `environment`

## Owner Mapping Rules

- Resolve each owner's read paths, work area, validation, and failure scope from the active project profile.
- The reusable defaults include agent-runtime, agent-query, agent-storage, agent-index, agent-tests, manager-main, and manager-harness; their target-specific responsibilities must be configured before dispatch.
- Missing tests or fixture gaps go to agent-tests.
- Cross-interface changes go to manager-main.
- Tooling, path, permission, and runtime problems go to manager-harness.
- This development checkout has no active target profile; do not infer one from historical project examples.

## Dispatch Procedure

1. inspect `latest_report.md`
2. confirm preflight is passing
3. inspect the most recent retry prompt
4. confirm failure type and owner mapping
5. adjust the owner if policy requires it
6. write a dispatch log entry
7. place an assignment in `assignments/<owner>/inbox/`
8. let the owner claim it into `in_progress/`
9. let the owner complete it into `done/`
10. rerun the harness cycle

## Escalation Rules

- if the same owner gets the same failure type twice in a row, escalate to `manager-main`
- if integration fails twice in a row, re-check whether the issue is really an interface problem
- do not dispatch new feature work while build is failing
- treat `Access is denied`, `Permission denied`, `UnauthorizedAccessException`, `EPERM`, and `EACCES` as `environment`
- if unauthorized path access or repository-root escape is detected, do not dispatch to a feature owner; `manager-harness` fixes it first
- stale `in_progress` assignments without an active invoke lock are recovered back to `inbox`
