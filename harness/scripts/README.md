# Harness Scripts

## Dashboard

`harness.ps1 dashboard` streams the local monitor URL and runs until Ctrl+C.
`start_harness_dashboard.ps1` launches the Python standard-library server;
`get_harness_dashboard.ps1` collects a read-only v1 snapshot using the existing
provider and completion-evidence contracts. `harness_dashboard_server.py` serves
only fixed assets and the snapshot API on loopback. See [usage](../docs/dashboard.md).
Tests: `test_harness_dashboard.ps1`, `test_harness_dashboard_server.py`,
`test_harness_dashboard_browser.js` (Playwright CLI run-code).

This checkout is for Harness development and has no active target project profile.
Operational examples below assume a configured target repository. See `../docs/feature_inventory.md` for the complete script inventory and implementation boundaries.

This directory contains the operational scripts used by the harness.

For the user-facing action list and command index, see `../docs/user_actions_and_commands.md`. Update that file whenever a user-visible workflow step or command changes.

## Core Validation Commands

Provider contract/adapter modules: `provider_contract.ps1`, `provider_codex.ps1`, `provider_claude.ps1`.
`test_provider_contract.ps1` and `test_provider_claude.ps1` cover categorized unit/integration/security cases
and is included in the self-test entry point. See [contract and compatibility](../docs/provider_contract.md).
Invocation command names remain compatible; unsupported provider names fail before launch.
Claude configuration, permissions and usage semantics: [Claude adapter](../docs/claude_adapter.md).

Unified entry: `pwsh -NoProfile -File scripts/harness.ps1 help` (installed nested
targets use `harness/scripts/harness.ps1`). Commands: init, doctor, run, status,
resume, usage, test. `-Preview` only resolves a call; seed `-DryRun` may write
reports/install hooks. Resume reports by default and executes only with `-Execute`.
See [CLI contract](../docs/cli.md). Existing script entry points remain supported.

Assignment success now requires execution evidence. `complete_assignment.ps1 -Result pass`
runs the assignment's validation command; a pass marker alone is unverified.
Use `-Revalidate` with the same owner/assignment ID and `-Result pass` to explicitly
refresh an existing completed pass after inspecting its source and worker exit.
See [evidence contract and limitations](../docs/assignment_evidence.md).
Run `test_assignment_evidence.ps1` for isolated evidence regressions; it is also
included in `test_harness.ps1`.

Preferred PowerShell entry points:

- `run_harness_preflight.ps1`
- `run_harness_cycle.ps1`
- `get_harness_status.ps1`
- `generate_env_manifest.ps1`
- `generate_profile_docs.ps1`
- `generate_retry_prompt.ps1`
- `dispatch_retry_prompt.ps1`
- `run_retry_handoff.ps1`
- `dispatch_seed_plan.ps1`
- `run_seed_handoff.ps1`
- `get_seed_handoff_resume.ps1`
- `send_harness_notification.ps1`
- `install_dev_environment.ps1`
- `audit_dev_environment.ps1`
- `install_service_contract.ps1`
- `audit_service_contract.ps1`
- `run_service_contract.ps1`
- `audit_ci_matrix.ps1`
- `install_release_provenance_workflow.ps1`
- `audit_release_provenance.ps1`
- `install_security_baseline.ps1`
- `audit_security_baseline.ps1`
- `install_precommit_baseline.ps1`
- `audit_precommit_baseline.ps1`
- `audit_generated_artifacts.ps1`
- `audit_porting_layout.ps1`
- `audit_git_remote_auth.ps1`
- `bootstrap_initial_commit.ps1`
- `init_project_adapter.ps1`
- `claim_assignment.ps1`
- `complete_assignment.ps1`

Shell wrappers also exist for the basic validation loop, but on Windows the PowerShell scripts are the primary path.
PowerShell Core (`pwsh`) is the preferred runtime on Linux, macOS, and modern Windows. Windows PowerShell remains supported as a fallback for Windows-only environments.
WSL counts as Linux here: install native `pwsh` inside WSL instead of relying on `powershell.exe`.
On Linux/macOS, `setup_portable_runtime.sh` normalizes shell executable bits, installs Git hooks, and runs preflight.
`run_portable_smoke.sh` creates a temporary target repository and verifies the Linux/macOS bootstrap path end to end.
`run_operational_smoke.sh` creates a temporary target repository and verifies retry, assignment, seed handoff, and fake live Codex behavior without a real target application.
`run_pr_control_smoke.sh` creates a temporary target repository with a fake `gh` executable and verifies PR open, check status, and guarded merge control without contacting GitHub.
`run_github_policy_smoke.sh` creates a temporary target repository with a fake `gh api` implementation and verifies GitHub ruleset audit/install behavior without contacting GitHub.
`run_platform_engineering_smoke.sh` creates a temporary target repository and verifies devcontainer/toolchain, service contract, CI matrix/cache, and release provenance generation without network access.
`run_security_quality_smoke.sh` creates a temporary target repository with a fake `gh` executable and verifies Dependabot, CodeQL, OpenSSF Scorecard, GitHub security setting audit, and pre-commit baseline behavior without contacting GitHub.

`run_seed_handoff.ps1` refreshes the local Git hook installation before preflight so isolated worktrees use the shared repository hooks instead of branch-local copies.

`init_project_adapter.ps1` can choose default commands and owner mappings from `-Language` and `-Framework`, so most new projects only need a short project identity plus a preset.
It also seeds the target repository's root `AGENT.md`, requirements docs, subagent docs, `.gitignore`, and `.gitattributes`. With `-RunPreflight`, it installs the harness hooks before running preflight.

`start_from_intake.ps1` reads a filled `docs/project_intake.md`, runs adapter initialization, applies command overrides, updates requirements/source docs when forced, and can generate a seed plan plus dry-run handoff.
It runs `review_project_intake.ps1` first unless `-SkipIntakeReview` is passed. The review blocks unresolved requirements, external setup gaps, and avoidable retry risks by default; `-AllowDeferredClarifications` records unresolved questions and continues.
The review also records Git baseline readiness. A first commit is not required for intake or seed dry-run, but live worker dispatch is reported as `needed_before_live` until `git rev-parse --verify HEAD` succeeds.
It also generates `docs/env_manifest.md`, `.env.example`, and `harness/reports/sensitive_followups.md` from prepared data, external dependency, and secret/access intake sections. Real secret values are never written; only variable names and local/mock setup notes are recorded.

`get_harness_status.ps1` writes `harness/reports/status.json` and `harness/reports/status.md`, then prints the current phase, next action, and next command. It is a snapshot command, not a blocking approval flow.
When the latest failure looks like `secret`, `requirements`, `environment`, or `worker`, the status snapshot records whether retry is appropriate and whether user action is required.

`get_seed_handoff_resume.ps1` writes `harness/reports/seed_plans/<plan-id>__resume.md` and `.json` for a seed plan. It shows passed, pending, running, failed, missing, and recoverable assignments, plus the exact resume command.
`run_seed_handoff.ps1 -Resume` skips passed assignments, reuses pending assignments, requeues failed assignments with previous failure analysis, and refuses to double-run an assignment that still has an active invoke lock.

`send_harness_notification.ps1` sends status attention events to Telegram when `HARNESS_NOTIFY_PROVIDER=telegram`, `HARNESS_TELEGRAM_BOT_TOKEN`, and `HARNESS_TELEGRAM_CHAT_ID` are set. `get_harness_status.ps1` calls it quietly after each status snapshot, and duplicate signatures are suppressed under `harness/state/notifications/`.

`audit_generated_artifacts.ps1` checks whether harness reports, state, assignment queues, and generated audit files are staged or missing from `.gitignore`.
`audit_porting_layout.ps1` checks that the reusable engine is nested under `harness/` instead of unpacked into the repository root.
`audit_git_remote_auth.ps1` separates Git remote reachability from GitHub CLI and API authentication.
`bootstrap_initial_commit.ps1` plans and optionally executes the first protected baseline commit flow; run `-DryRun` first.

Preset examples:

```powershell
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName my-api -Language python -Framework fastapi -Force -RunPreflight
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName my-web -Language typescript -Framework next -Force -RunPreflight
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName my-db -Language c11 -Framework none -Force -RunPreflight
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName my-web -Requirements "Build a Next.js dashboard with login and charts" -Force -RunPreflight
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName my-tool -RequirementsFile docs/product_brief.md -Interactive -Force -RunPreflight
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ListPresets
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -CreateTemplate
pwsh -NoProfile -File harness/scripts/review_project_intake.ps1 -IntakeFile docs/project_intake.md -RequireSeedPlan
pwsh -NoProfile -File harness/scripts/generate_env_manifest.ps1 -IntakeFile docs/project_intake.md
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun -AllowDeferredClarifications
pwsh -NoProfile -File harness/scripts/get_harness_status.ps1
pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -DryRun -Force -Message "Harness notification test" -Provider telegram
pwsh -NoProfile -File harness/scripts/install_dev_environment.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_dev_environment.ps1
pwsh -NoProfile -File harness/scripts/install_service_contract.ps1 -Preset postgres-redis -Force
pwsh -NoProfile -File harness/scripts/audit_service_contract.ps1
pwsh -NoProfile -File harness/scripts/install_release_provenance_workflow.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_release_provenance.ps1
pwsh -NoProfile -File harness/scripts/install_security_baseline.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1
pwsh -NoProfile -File harness/scripts/install_precommit_baseline.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_precommit_baseline.ps1
pwsh -NoProfile -File harness/scripts/audit_generated_artifacts.ps1
pwsh -NoProfile -File harness/scripts/audit_porting_layout.ps1
pwsh -NoProfile -File harness/scripts/audit_git_remote_auth.ps1 -CheckGitHubApi
pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -DryRun
```

When requirements are supplied without an explicit stack, the script tries to infer a language, framework, and application type. If inference is not confident enough, rerun with `-Interactive` so it can ask for the missing environment choices.

## Baseline Workflow

Run the baseline in this order:

1. `run_harness_preflight.ps1`
2. `run_harness_cycle.ps1`
3. `generate_profile_docs.ps1`
4. `run_retry_handoff.ps1 -DryRun` when you need to verify the handoff path without starting Codex
5. `run_seed_handoff.ps1 -DryRun` when `manager-main` has already written a seed plan and you want one-session worker startup

Recommended commands:

```powershell
pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1
pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1
pwsh -NoProfile -File harness/scripts/generate_profile_docs.ps1
pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1 -DryRun -PromptId <prompt-id>
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -DryRun -PlanFile harness/reports/seed_plans/<plan-file>.md
```

Portable platform smoke from the harness checkout:

```sh
sh scripts/run_portable_smoke.sh
```

Portable operational smoke from the harness checkout:

```sh
sh scripts/run_operational_smoke.sh
```

Git hook smoke from the harness checkout:

```sh
sh scripts/run_git_hook_smoke.sh
```

PR control smoke from the harness checkout:

```sh
sh scripts/run_pr_control_smoke.sh
```

GitHub policy smoke from the harness checkout:

```sh
sh scripts/run_github_policy_smoke.sh
```

Platform engineering smoke from the harness checkout:

```sh
sh scripts/run_platform_engineering_smoke.sh
```

Security and quality smoke from the harness checkout:

```sh
sh scripts/run_security_quality_smoke.sh
```

Live seed handoff defaults to:

- retry a failed worker assignment up to 3 attempts
- continue to later assignments unless `-StopOnWorkerFailure` is set
- automatically advance all-passing feature branches through `dev`
- create a final `test/*` candidate and request `main` approval
- stop before `main` approval/merge; that step remains manual

## Validation Artifacts

Validation writes to:

- `harness/reports/preflight_report.md`
- `harness/reports/latest_report.md`
- `harness/reports/status.md`
- `harness/reports/status.json`
- `harness/reports/sensitive_followups.md`
- `harness/reports/notifications_log.md`
- `harness/reports/dev_environment_audit.md`
- `harness/reports/service_contract_audit.md`
- `harness/reports/ci_matrix_audit.md`
- `harness/reports/release_provenance_audit.md`
- `harness/reports/security_baseline_audit.md`
- `harness/reports/precommit_baseline_audit.md`
- `harness/reports/test_results/`
- `harness/reports/logs/`

Handoff writes to:

- `harness/reports/retry_prompts/`
- `harness/reports/seed_plans/`
- `harness/reports/dispatch_packets/`
- `harness/reports/agent_runs/`
- `harness/reports/dispatch_log.md`
- `harness/reports/seed_dispatch_log.md`
- `harness/reports/assignment_log.md`
- `harness/reports/live_dispatch_log.md`

## Assignment Flow

Assignments move through three states:

1. `inbox`
2. `in_progress`
3. `done`

Use `AssignmentId` when more than one assignment exists for the same owner.

Failed harness cycles generate retry prompts automatically unless `-SkipRetryPrompt` is used.

Initial multi-owner implementation can be seeded from a `manager-main` plan file and dispatched through `run_seed_handoff.ps1`.

## Safety Expectations

- harness path settings and owner work areas must stay inside the repository root
- report and state paths must be writable during preflight
- assignment state transitions must not delete the source file before the target is safely written
- UTF-8 without BOM is the default file encoding for harness-generated files
- stale `in_progress` assignments without an active invoke lock are recovered back to `inbox`
- live worker execution expects an assignment-specific feature branch and uses an isolated worktree under `harness/state/worktrees`
- serial seed handoff still dispatches one assignment at a time, but each live run now uses its own isolated worktree instead of the shared repository root
- live seed handoff can keep going after worker failure by requeueing the failed assignment until `MaxWorkerAttempts` is reached
- live seed handoff appends previous worker output into the retry packet so the next attempt can analyze the failure before changing code
- resume mode skips already passing assignments, requeues failed assignments, and leaves actively running assignments alone
- Telegram notification tokens and chat ids must come from environment variables, not committed files
- automatic git advance stops at a requested main approval; it does not approve or merge `main`

## Git Workflow

Install local Git enforcement before commit, push, or merge:

```powershell
pwsh -NoProfile -File harness/scripts/install_git_hooks.ps1
```

Required gate flow:

1. On `<owner>/<task>`, commit freely; before pushing, seal the candidate tree and run (add `-AllowCommittedHead` for an already committed head):

```powershell
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature
```

2. Before promoting into `dev`, run the integration gate and record the promotion:

```powershell
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage integration
pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <feature-branch> -TargetBranch dev
pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <feature-branch> -TargetBranch dev
```

3. On `test/<candidate>`, run the final gate and approval flow:

```powershell
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage final
pwsh -NoProfile -File harness/scripts/request_main_merge_approval.ps1 -SourceBranch <test-branch>
pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId <approval-id> -Status approved -Approver <name>
pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <test-branch> -TargetBranch main -ApprovalId <approval-id>
pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <test-branch> -TargetBranch main
```

Hybrid PR path for `main` can be used instead of the local-only final merge:

```powershell
pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1
pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1
pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1
pwsh -NoProfile -File harness/scripts/open_pr_candidate.ps1 -SourceBranch <test-branch>
pwsh -NoProfile -File harness/scripts/check_pr_status.ps1 -PullRequest <pr-number-or-branch>
pwsh -NoProfile -File harness/scripts/merge_pr_if_allowed.ps1 -PullRequest <pr-number-or-branch> -ApprovalId <approval-id>
```

The PR and policy scripts use GitHub CLI `gh`. Run `gh auth login` once in the target repository environment, or set `HARNESS_GH_PATH` to the absolute executable path when `gh` is not on `PATH`. Ruleset installation requires repository administration permission.

Protected branches reject direct commits. The only exception is the first bootstrap commit on `main`, which requires `run_git_gate.ps1 -Stage bootstrap` and an approved bootstrap request before push.
## Engine development tests

From the Harness development root, run `pwsh -NoProfile -File scripts/test_harness.ps1`.
`-SyntaxOnly` checks script syntax and JSON only. `test_harness_safety.ps1` runs the isolated regression suite; `test_lock_child.ps1` is its subprocess fixture.
`test_harness_recovery.ps1` also runs from the common test entry point. Its `test_recovery_child.ps1` fixture tests process termination, concurrent journal recovery and orphan workers with no provider calls.
These commands need Git and PowerShell, but no project profile, AI provider or external API.
Artifacts are kept under `.test-output/`. See `../docs/improvement_backlog.md` for migration details and unverified areas.

`assignment_state.ps1` is loaded by the common module. `run_assignment_worker.ps1` is an internal host invoked only with a matching durable invocation ID. `repair_assignment_state.ps1 -Agent <owner> [-AssignmentId <id>]` reconciles journals and confirmed exits in a configured target. See `../docs/recovery_design.md` for the state contract, blocked cases and deployment requirements. `HARNESS_CODEX_PATH` selects an explicit CLI executable, including a fake CLI for offline tests.

# 2026-10-15 추가 진입점

- `get_execution_usage.ps1 [-Json]`: 실행별 예약·토큰·시간·시도 횟수 조회. 금액이나 구독 잔여량을 추정하지 않음.
- `execution_usage.ps1`: worker 사용량 기록 및 공통 lease 안에서 다음 실행 정책 검사.
- `harness_layout.ps1`, `hook_bootstrap.sh`: 독립/이식 경로와 worktree hook 정책 루트 처리.
- `test_execution_usage.ps1`, `test_harness_layout.ps1`: 네트워크/유료 AI 없는 회귀. `test_harness.ps1`에 포함.
- 개별 검증·cycle·retry shell은 `invoke_harness.sh` → `run_harness_shell.ps1`로 위임. `validation_command.ps1`이 cycle과 동일한 프로필 명령을 해석·실행합니다. [Shell 계약과 전환](../docs/shell_commands.md) 참고.
- `test_harness_shell.ps1`: 실제 Node CLI 도구를 만드는 두 배치 유닛·통합·보안 회귀. Node.js와 Git POSIX shell이 필요하며 전체 자체 테스트에 포함됩니다.
- `test_harness_entrypoints.ps1`: 같은 격리 fixture를 PowerShell 직접 호출·Bash·Windows CMD로 실행합니다. 전체 자체 테스트가 shell fixture를 재사용해 연결하며 단독 실행 시 fixture를 생성합니다. Windows 30개, Linux 20개입니다.

운영 범위는 [배치 지원](../docs/layout_support.md), [사용량 정책](../docs/execution_usage.md)을 참고하세요.

