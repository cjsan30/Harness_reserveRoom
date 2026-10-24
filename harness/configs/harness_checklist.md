# Harness Checklist

## 1. Single Source Of Truth

- `harness/project/configs/project_profile.json` exists
- project identity, commands, owners, dispatch, failure patterns, Git workflow, and harness paths are defined in the profile
- generated profile documentation can be refreshed from the profile
- a filled `docs/project_intake.md` can generate or refresh the profile, requirements docs, and seed plan
- intake review can block ambiguous requirements, missing external access details, and avoidable worker retry risks before live development starts
- intake review reports whether a Git baseline commit is ready for live worker dispatch
- intake startup generates `docs/env_manifest.md`, `.env.example`, and `harness/reports/sensitive_followups.md` without storing real secrets

## 2. Validation Pipeline

- build passes
- unit tests exist and run
- integration tests exist and run
- benchmark smoke exists and runs
- full-cycle execution is available through `run_harness_cycle.ps1`

## 3. Failure Model

- failures are classified and recorded
- permission errors such as `Access is denied` are classified as `environment`
- missing secret/env setup is classified as `secret`
- unresolved product or requirement gaps are classified as `requirements`
- incomplete live worker execution is classified as `worker`
- latest report captures status, failing module, next owner, and next task
- status snapshot records retryability and user-action requirements for the latest failure
- suite logs are written under `harness/reports/logs/`

## 4. Retry And Dispatch

- failed cycles generate a retry prompt under `harness/reports/retry_prompts/`
- retry work is assigned to a concrete owner
- dispatch log is updated
- manager-harness can inspect the retry prompt and decide the next owner
- operational smoke verifies retry dry-run dispatch without a real target application
- intake seed dry-run verifies first assignments can be packaged before live worker launch
- seed handoff resume report shows passed, pending, running, failed, missing, and recoverable assignments
- live seed resume skips passed assignments and requeues failed assignments with previous failure analysis

## 5. Assignment Lifecycle

- assignment inbox files are created
- claim moves an assignment into `in_progress`
- complete moves an assignment into `done`
- assignment log is updated
- dry-run or live handoff artifacts are written for worker invocation
- fake live worker smoke verifies incomplete workers are marked `fail`, not `pass`
- fake live worker smoke verifies explicit worker completion can mark an assignment `pass`
- stale `in_progress` work can be recovered safely

## 6. Safety Controls

- owner paths and harness paths cannot escape the repository root
- report and state paths are write-tested during preflight
- assignment state movement does not delete the source before the target is safely written
- harness-generated files are written in UTF-8
- notification tokens are read from environment variables and are not committed
- duplicate notification signatures are suppressed under `harness/state/notifications/`
- devcontainer and toolchain manifest exist when shared development environment setup is required
- service contract does not contain real secret-like values
- security baseline files exist for Dependabot, Scorecard, and supported CodeQL languages
- pre-commit baseline exists for lightweight formatting, private-key, file-size, YAML/JSON, and line-ending checks

## 7. Git Governance

- `.gitignore` exists for generated artifacts used by validation and harness runs
- `.gitattributes` exists for line-ending and binary handling
- `core.hooksPath` points to the repository's absolute `.githooks` path
- `.githooks/pre-commit`, `.githooks/pre-push`, `.githooks/pre-merge-commit`, and `.githooks/pre-rebase` exist and are executable on Linux/macOS
- hook path conversion is centralized through `harness/scripts/path_common.sh` and does not convert `/mnt/c/...` through `wslpath -u` again
- PowerShell shell wrappers and Git hooks use writable XDG runtime directories outside the repository so runtime cache files do not dirty Git gate inputs
- generated harness reports, state, and assignment queue files are ignored and not staged in the candidate tree
- porting layout audit confirms the reusable harness lives under `harness/`, not unpacked into the repository root
- feature branches use the `<owner>/<task>` shape (empty `feature_branch_prefix`); no owner is named `main`, `dev`, or `test`
- final test branches use the `test/<candidate>` shape
- live subagent runs use assignment-specific feature branches
- commit is blocked unless the exact tree passed the correct gate
- push is blocked unless the current `HEAD` tree passed the correct gate
- direct refspec pushes into protected branches are blocked
- protected branch rebases are blocked
- merge into `dev` is blocked unless feature and integration gates passed and promotion was authorized
- merge into `main` is blocked unless final gate passed, approval exists, and promotion was authorized
- hybrid PR merge into `main` is blocked unless the PR source head matches local approval, final gate passed, and required PR checks pass
- PR control smoke verifies PR open, PR checks, and guarded PR merge behavior with a fake `gh`
- GitHub policy audit verifies the server ruleset protects `main` with PR-only updates, delete and force-push protection, strict required checks, and the configured review count
- GitHub policy smoke verifies server ruleset audit/install behavior with a fake `gh api`
- CI matrix/cache audit verifies `Harness CI` remains the required-check aggregator while matrix jobs run stack-specific setup and cache steps
- release provenance audit verifies artifact upload and GitHub attestation workflow markers
- security baseline audit verifies Dependabot, CodeQL when supported, OpenSSF Scorecard, and optional GitHub security settings
- pre-commit audit verifies quality hooks without replacing harness Git workflow governance

## 8. Repository Hygiene

- generated harness artifacts stay ignored by Git
- documentation entry points are readable and not mojibake-corrupted
- line endings are controlled by repository attributes instead of per-machine defaults

## 9. Operational Proof

- `run_harness_preflight.ps1` passes
- `audit_generated_artifacts.ps1` and `audit_porting_layout.ps1` pass
- `run_harness_cycle.ps1` passes
- per-suite records exist under `harness/reports/test_results/`
- current status snapshot exists under `harness/reports/status.md` and `harness/reports/status.json`
- notification dry-run can send or preview an attention message without writing secrets to Git
- a current dry-run or preflight-only handoff record exists under `harness/reports/agent_runs/`
- platform engineering smoke passes for dev environment, service contract, CI matrix/cache, and release provenance generation
- security and quality smoke passes for security baseline and pre-commit generation
- current state documentation matches the actual harness status
