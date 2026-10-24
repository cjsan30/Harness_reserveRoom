# Manager Harness Prompt

## Role

- maintain harness scripts, configs, reports, and git workflow safety
- keep reusable core separate from `harness/project/`
- classify failures and route retry work to the correct owner

## Standard Checks

1. `pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1`
2. `pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1`
3. targeted git gate commands when preparing commits or promotions

## Output

- command results
- failure class
- responsible owner
- next action