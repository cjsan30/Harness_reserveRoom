# Project Intake

Fill this file, then run:

```powershell
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun
```

## Project

- project_name:
- summary:
- language:
- runtime:
- framework:
- ide:
- application_type:

## Start Policy

- clarification_mode: resolve_before_start

Use `defer_allowed` only when you want the harness to start and let workers ask unresolved questions later.

## Commands

- build_command:
- unit_command:
- integration_command:
- benchmark_smoke_command:
- release_command:

Leave command values blank to use the harness preset for the selected language/framework.

## Requirements

Describe what must be built. Keep this concrete enough that a worker can decide what code and tests are needed.

## Success Criteria

- build passes
- unit tests pass
- integration tests pass

## Constraints

- no known constraints

## Assumptions

- none

## Prepared Data

- none

## External Dependencies

- none

## Secrets And Access

Use one environment variable name per line, such as `- SERVICE_API_KEY`.
Never enter values. This section's descriptions/values are omitted from generated artifacts.
Put non-secret setup instructions in External Dependencies.

- none

## Source Links

- none

## Seed Plan

- plan_id:
- dispatch_mode: serial

Add one or more `## Seed Assignment` blocks when you want the harness to create a seed plan.

## Seed Assignment

- owner:
- title:
- work_area:
- validation:

### Task

Write a concrete task for this owner.

### Acceptance

- observable pass condition

### Notes

none
