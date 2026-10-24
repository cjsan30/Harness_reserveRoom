# Manager Main Seed Plan Format

Use this when manager-main needs to create executable subagent work.

Write seed plans under `harness/reports/seed_plans/`.

## Required Shape

```md
# Assignment Seed Plan

## Meta

- plan_id: <short-unique-id>
- summary: <one-line summary>
- dispatch_mode: serial

## Assignment

- owner: <owner from project profile>
- title: <short stable task title>
- work_area: <optional override>
- validation: <optional override>

### Task

<concrete task>

### Acceptance

- <observable pass condition>

### Notes

none
```