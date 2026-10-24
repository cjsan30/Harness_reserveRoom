# User Actions And Commands

## Read-only dashboard

`pwsh -NoProfile -File scripts/harness.ps1 dashboard` starts a loopback-only monitor and opens the browser.
Use `-NoOpen`, `-Port 8768`, `-RefreshSeconds 10` or `-PythonExecutable <path>` as needed.
Python 3.9+ is required only for the server. Stop it with Ctrl+C.
`dashboard -Snapshot -Json` reads once without server/Python, mutations or notifications.
`dashboard -Preview -Json` returns the call plan. Server mode does not accept `-Json`.
For nested layouts prefix `scripts/` with `harness/`. [Data semantics and limits](dashboard.md).

## Shell validation commands

`sh harness/scripts/run_unit.sh --preview` shows the bound project and configured command without executing the project tool.
Remove `--preview` to run; build/integration/benchmark_smoke work the same way.
For standalone installs remove the `harness/` prefix. Cycle supports `--skip-retry-prompt`; retry delegates to the current PowerShell generator.
Unknown arguments now fail instead of being ignored. Configure tool arguments and make targets in the profile.
Read the [shell contract and migration guide](shell_commands.md) for exit codes, runtime and root/workspace checks.

`pwsh -NoProfile -File scripts/test_harness_entrypoints.ps1` creates isolated real CLI fixtures and compares native PowerShell/Bash calls, plus CMD on Windows. It is included in the full self-test. The optional `-FixtureDirectory` is for a previous shell-test output directory, never a production project. The fixtures' commands are temporarily changed for failure tests and restored afterward.

`test_harness_shell.ps1 -CasePattern '*relocated*'` reruns only the two relocation cases. Filtered pass counts are not whole-suite results. See actual platform coverage for WSL/Linux filesystem and runtime details.

## Harness Development Checkout

This checkout contains the reusable engine and no active target project profile.
The commands below describe a configured target repository with the engine under `harness/`.
Review current development state before running operational commands here.
The complete implemented feature and script list is in [feature_inventory.md](feature_inventory.md).
Use `pwsh -NoProfile -File scripts/init_project_adapter.ps1 -ListPresets` from this checkout to inspect presets without creating a target configuration.

This file is the user-facing index for what a user must do, what the harness does, and which commands are available.

Maintenance rule: whenever a user action, workflow step, script, or command changes, update this file in the same change. Also update `configs/commands.md` when the command list changes.

## User Responsibilities

### Provider Contract

The optional target-profile `worker_provider` object accepts `{ "version": 1, "name": "codex" }` or name `claude`.
Omitting it preserves existing Codex behavior; invalid or unsupported values are rejected.
Claude uses `HARNESS_CLAUDE_PATH` or PATH, print stream-json, acceptEdits and denied unattended permission prompts.
Existing invocation command names remain available, including `invoke_assignment_codex.ps1`.
Configure the target's Claude permissions for the required validation/completion shell commands; the adapter does not grant unrestricted Bash or bypass permissions.
`-Ephemeral` disables Claude session persistence, not Harness audit records. See [Claude setup and limits](claude_adapter.md).
Inspect provider/result/usage fields with `scripts/harness.ps1 usage -Json`.
Never delete provider metadata or reservations to bypass a failed/unconfirmed run.
See [contract, migration and result meaning](provider_contract.md).
Run `scripts/test_provider_contract.ps1` and `scripts/test_provider_claude.ps1` for categorized isolated regressions without paid calls.

### Unified CLI

Run `pwsh -NoProfile -File scripts/harness.ps1 help` from standalone targets
(use `harness/scripts/harness.ps1` for nested targets). `-Root` selects an installed
target. `-Preview` displays the resolved script/parameters without executing it.
Seed `-DryRun` still uses the existing workflow and can install hooks/write reports.
`run` requires an explicit `-PlanFile` and executes live by default; `resume` reports
only unless `-Execute` is supplied. No new approval bypass is introduced.
`-Json` uses a v1 envelope; query success is distinct from project readiness.
See [all commands, side effects and exit codes](cli.md).

`test_harness_cli.ps1` provides categorized unit/integration/security checks and is
included in the engine test entry point.

### Assignment Success Evidence

`complete_assignment.ps1 -Result pass` now executes the assignment's unique
`validation` command and requires unchanged source/Git state and a recorded log.
Existing pass markers without valid evidence are `unverified`; status reports
exclude them from success and seed promotion stops.

After inspecting a completed assignment and confirmed successful worker exit,
run `pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <id> -Result pass -Revalidate`
from a configured nested target (omit `harness/` for standalone). This executes
validation again and retains old evidence. A nonzero or unresolved worker exit
cannot be overridden by revalidation. See [contract and limits](assignment_evidence.md).

Development-only regression command: `pwsh -NoProfile -File scripts/test_assignment_evidence.ps1`.

### Engine Development Verification

Run `pwsh -NoProfile -File scripts/test_harness.ps1` from the development checkout.
It checks PowerShell syntax/configuration JSON and uses fresh local Git repositories and a fake GitHub CLI for regression tests.
No provider key, account login, active target profile, or network access is required.
Results and diagnostic fixtures remain in ignored `.test-output/<run-id>/`; no existing repository is reset or cleaned.
Use `-SyntaxOnly` for the parser checks alone. `test_lock_child.ps1` is an internal subprocess fixture, not a user command.

### Safety Update Migration

- Existing approval records without `repository_root` are no longer valid authorization. Request and decide a new approval after validation.
- Moving/copying a target repository invalidates its old approval binding; request approval at the new location.
- Keep the same lease object returned by `Acquire-HarnessLock` when releasing or updating a lock.
- New lock directories and their `lease` files remain after release. Their presence does not mean a worker is active.
- Do not delete new lease files while any Harness process is running. Old directories without a `lease` file are deliberately not auto-reclaimed: stop old workers, verify they are stopped, and remove only their specific obsolete lock directories before upgrading.
- `Secrets And Access` accepts one uppercase environment-variable name per line. Values, descriptions, and other free text in that section are discarded from generated artifacts. Keep access instructions without credentials in `External Dependencies`.
- Common credential patterns outside the sensitive section block intake before generation. This is not a detector for arbitrary secret strings; never place real credentials in intake.
- A concurrent workflow state update stops the losing operation with a conflict. Rerun it against the new state rather than overwriting the state file.

### New Project Intake

The user fills `docs/project_intake.md` with:

- project summary and target stack
- requirements and success criteria
- constraints and assumptions
- prepared data and external dependencies
- secret or environment variable names only, never real secret values
- seed assignments when initial work should be dispatched

If the harness reports missing or ambiguous information, the user edits `docs/project_intake.md` using `docs/project_intake_questions.md`, then reruns intake start or intake review.

### Before Live Worker Dispatch

The user must make sure these are ready before live Codex workers run:

- intake review is `pass` or intentionally `deferred`
- preflight passes
- seed dry-run passes when using seed assignments
- Git has a committed baseline `HEAD`
- required non-secret setup and mock/local strategy are documented
- reproducible development environment and service contract are generated when the project has external runtime dependencies
- security baseline and pre-commit baseline are generated before shared development
- real secrets are available outside Git when live integrations require them

Seed dry-run can run before the first commit. Live worker dispatch cannot.

### During Development

The user normally does not approve each worker step. The harness continues through assignment dispatch, failure classification, retry, and resume when the failure is retryable.

The user is needed when status reports:

- unclear requirements or product decisions
- missing secret/env values that cannot be mocked
- local toolchain, permission, network, or Git setup problems
- baseline commit missing before live worker dispatch
- final `main` merge approval
- GitHub PR check failures or missing GitHub CLI authentication when using hybrid PR control
- missing GitHub repository administration permission when installing server rulesets

Active worker duplicate execution is not a user approval flow. The harness uses invoke locks to block a second live worker for the same assignment while one is active.

### Telegram Notifications

Use this when the user wants Telegram messages when the harness stops, fails, or needs user action.

1. Create a Telegram bot with `@BotFather`.
2. Send `/start` or any test message to the bot.
3. Get the `chat_id` from Telegram `getUpdates`.
4. Set these PowerShell environment variables outside Git:

```powershell
$env:HARNESS_NOTIFY_PROVIDER="telegram"
$env:HARNESS_NOTIFY_LEVEL="attention"
$env:HARNESS_TELEGRAM_BOT_TOKEN="<bot-token>"
$env:HARNESS_TELEGRAM_CHAT_ID="<chat-id>"
```

5. Send a test notification:

```powershell
pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -Force -Message "Harness notification test" -Provider telegram
```

6. Run status normally:

```powershell
pwsh -NoProfile -File harness/scripts/get_harness_status.ps1
```

After the environment variables are set, `get_harness_status.ps1` automatically calls Telegram notification delivery after each status snapshot. Duplicate notification signatures are suppressed, so the same unresolved state is not repeatedly sent.

Notification levels:

- `attention`: default; sends when the harness likely needs attention
- `action_required`: sends only when user action is explicitly required
- `failure`: sends only on failed or blocked statuses
- `all`: sends every status snapshot

To temporarily disable notifications:

```powershell
$env:HARNESS_NOTIFY_DISABLED="true"
```

Do not write the bot token into `docs/project_intake.md`, `.env.example`, committed config, screenshots, or reports.

### Status And Resume

Status commands are snapshots. They update reports when run, but they are not a live dashboard or daemon.

Use status and resume reports to decide the next command:

- `harness/reports/status.md`
- `harness/reports/status.json`
- `harness/reports/seed_plans/<plan-id>__resume.md`
- `harness/reports/seed_plans/<plan-id>__resume.json`

## Primary Flow

1. Create intake template.
2. Fill `docs/project_intake.md`.
3. Run intake start with preflight and seed dry-run.
4. Answer any questions written by intake review.
5. Create the first Git baseline commit before live workers.
6. Run live seed handoff when ready.
7. Use status or resume reports if execution stops.
8. Approve final `main` merge only after final gate and approval request.
9. If using hybrid PR control, open the PR, wait for required GitHub checks, then merge through the harness PR wrapper.
10. If using GitHub server enforcement, install and audit the GitHub ruleset after the repository is connected.
11. Generate dev environment, service contract, CI matrix/cache, and release provenance workflows when the project is ready for shared development or release.
12. Generate security baseline and pre-commit baseline before opening the repository to repeated PR work.

## Common Commands

### Intake

```powershell
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -CreateTemplate
pwsh -NoProfile -File harness/scripts/review_project_intake.ps1 -IntakeFile docs/project_intake.md -RequireSeedPlan
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun -AllowDeferredClarifications
```

### Environment Manifest

```powershell
pwsh -NoProfile -File harness/scripts/generate_env_manifest.ps1 -IntakeFile docs/project_intake.md
```

### Status

```powershell
pwsh -NoProfile -File harness/scripts/get_harness_status.ps1
pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md -RecoverStale
```

### Notifications

```powershell
$env:HARNESS_NOTIFY_PROVIDER="telegram"
$env:HARNESS_NOTIFY_LEVEL="attention"
$env:HARNESS_TELEGRAM_BOT_TOKEN="<bot-token>"
$env:HARNESS_TELEGRAM_CHAT_ID="<chat-id>"

pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -DryRun -Force -Message "Harness notification test" -Provider telegram
pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -Force -Message "Harness notification test" -Provider telegram
pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -StatusFile harness/reports/status.json -Provider telegram
pwsh -NoProfile -File harness/scripts/get_harness_status.ps1
```

The dry-run command previews the message without sending it. The force command sends a custom test message. The status command sends automatically only when the status matches the configured notification level.

### Validation

```powershell
pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1
pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1
pwsh -NoProfile -File harness/scripts/generate_profile_docs.ps1
pwsh -NoProfile -File harness/scripts/audit_generated_artifacts.ps1
pwsh -NoProfile -File harness/scripts/audit_porting_layout.ps1
pwsh -NoProfile -File harness/scripts/audit_git_remote_auth.ps1 -CheckGitHubApi
pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -DryRun
```

### Platform Engineering

```powershell
pwsh -NoProfile -File harness/scripts/install_dev_environment.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_dev_environment.ps1
pwsh -NoProfile -File harness/scripts/install_service_contract.ps1 -Preset postgres-redis -Force
pwsh -NoProfile -File harness/scripts/audit_service_contract.ps1
pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action up
pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action down
pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_ci_matrix.ps1
pwsh -NoProfile -File harness/scripts/install_release_provenance_workflow.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_release_provenance.ps1
```

`install_dev_environment.ps1` writes `.devcontainer/devcontainer.json` and `harness/project/configs/toolchain_manifest.json` from the active profile. `install_service_contract.ps1` writes a disposable local/CI service contract and optional `docker-compose.harness.yml`; never put production credentials there. The CI workflow keeps `Harness CI` as the required-check aggregator while matrix jobs run stack-specific cache and setup steps. The release provenance workflow uploads release artifacts and uses GitHub artifact attestations.

### Security And Pre-commit

```powershell
pwsh -NoProfile -File harness/scripts/install_security_baseline.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1
pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1 -CheckGitHubSecuritySettings
pwsh -NoProfile -File harness/scripts/install_precommit_baseline.ps1 -Force
pwsh -NoProfile -File harness/scripts/audit_precommit_baseline.ps1
```

`install_security_baseline.ps1` writes Dependabot, CodeQL when the active stack is supported, OpenSSF Scorecard, and `harness/project/configs/security_baseline.json`. Secret scanning and push protection are GitHub repository settings, so `audit_security_baseline.ps1 -CheckGitHubSecuritySettings` checks them through `gh` when repository access is available. `install_precommit_baseline.ps1` writes `.pre-commit-config.yaml` for lightweight formatting, file size, YAML/JSON, private-key, line-ending, and stack-specific quick checks. Harness Git hooks still own branch/gate/push/merge governance.

### Live And Resume Handoff

```powershell
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1
```

Preview without launching live Codex:

```powershell
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -DryRun -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -KeepMergedAssignmentBranches -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1 -DryRun
```

### Assignment Utilities

```powershell
pwsh -NoProfile -File harness/scripts/claim_assignment.ps1 -Agent <owner> -AssignmentId <assignment-id>
pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <assignment-id> -Result pass
pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <assignment-id> -Result fail
pwsh -NoProfile -File harness/scripts/invoke_assignment_codex.ps1 -Agent <owner> -AssignmentId <assignment-id>
pwsh -NoProfile -File harness/scripts/invoke_pending_assignment_codex.ps1 -Agent <owner>
```

### Git Workflow

```powershell
pwsh -NoProfile -File harness/scripts/install_git_hooks.ps1
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage bootstrap
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature -AllowCommittedHead
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage integration
pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage final
pwsh -NoProfile -File harness/scripts/audit_git_workflow.ps1
pwsh -NoProfile -File harness/scripts/approve_branch_deletion.ps1 -Branch <branch> -Approver <name> -Reason <why>
pwsh -NoProfile -File harness/scripts/request_main_merge_approval.ps1 -SourceBranch <test-branch>
pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId <approval-id> -Status approved -Approver <name>
pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <feature-branch> -TargetBranch dev
pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <feature-branch> -TargetBranch dev
pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <test-branch> -TargetBranch main -ApprovalId <approval-id>
pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <test-branch> -TargetBranch main
pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1
pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1
pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1
pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1 -Branch dev -ProtectionOnly
pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1 -Branch dev -ProtectionOnly
pwsh -NoProfile -File harness/scripts/open_pr_candidate.ps1 -SourceBranch <test-branch>
pwsh -NoProfile -File harness/scripts/check_pr_status.ps1 -PullRequest <pr-number-or-branch>
pwsh -NoProfile -File harness/scripts/merge_pr_if_allowed.ps1 -PullRequest <pr-number-or-branch> -ApprovalId <approval-id>
```

Git gate commands must be real validation commands. No-op or failure-masking commands such as `true`, `exit 0`, or `|| true` are rejected.

Hybrid PR control keeps the local harness approval as the human decision point, then lets GitHub Actions provide the remote test gate. `open_pr_candidate.ps1` requires a passing final gate for the exact `test/*` tree. `merge_pr_if_allowed.ps1` requires the approved local main approval, the same source head, required PR checks passing, and then calls `gh pr merge --match-head-commit`.

For server-side enforcement, install and merge `.github/workflows/harness-ci.yml`, then configure that check as required in GitHub branch protection or rulesets.

The harness can install its own repository ruleset after `origin` points at GitHub and `gh auth login` has completed with repository administration permission:

```powershell
pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1
pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1
pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1
```

The default ruleset protects `main`, blocks delete and force-push, requires PRs, requires one approving review, requires resolved review threads, and requires the `Harness CI` status check with latest-base strictness. For solo repositories, `-RequiredApprovals 0` is available, but that weakens server-side human approval.

Before using hybrid PR control, install and authenticate GitHub CLI:

```powershell
gh auth login
```

Git remote credentials and GitHub CLI credentials are separate. Before relying on push, PR, or ruleset automation, run:

```powershell
pwsh -NoProfile -File harness/scripts/audit_git_remote_auth.ps1 -CheckGitHubApi
```

For a new repository's first protected baseline commit, plan the candidate files first:

```powershell
pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -DryRun
```

Then run the real bootstrap only after the candidate list excludes generated harness reports/state:

```powershell
pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -Commit -RequestApproval
```

If `gh` is installed outside `PATH`, set:

```powershell
$env:HARNESS_GH_PATH="<absolute-path-to-gh>"
```

### Portable Setup And Smoke

From a target repository:

```sh
sh harness/scripts/setup_portable_runtime.sh
```

From this harness checkout:

```sh
sh scripts/run_portable_smoke.sh
sh scripts/run_operational_smoke.sh
sh scripts/run_git_hook_smoke.sh
sh scripts/run_pr_control_smoke.sh
sh scripts/run_github_policy_smoke.sh
sh scripts/run_platform_engineering_smoke.sh
sh scripts/run_security_quality_smoke.sh
```

Linux/macOS shell wrappers and Git hooks automatically put PowerShell runtime cache/data/config files under `${TMPDIR:-/tmp}/codex-harness-xdg/` so Git gate checks do not see those files as repository changes. Set `CODEX_HARNESS_XDG_ROOT` only if you need a different writable location.

## Output Files To Check

- `docs/project_intake_questions.md`
- `docs/env_manifest.md`
- `.env.example`
- `harness/reports/intake_review_report.md`
- `harness/reports/sensitive_followups.md`
- `harness/reports/preflight_report.md`
- `harness/reports/latest_report.md`
- `harness/reports/status.md`
- `harness/reports/status.json`
- `harness/reports/seed_plans/<plan-id>__dispatch_summary.md`
- `harness/reports/seed_plans/<plan-id>__resume.md`
- `harness/reports/agent_runs/`
- `harness/reports/live_dispatch_log.md`
- `harness/reports/notifications_log.md`
- `harness/reports/dev_environment_audit.md`
- `harness/reports/service_contract_audit.md`
- `harness/reports/ci_matrix_audit.md`
- `harness/reports/release_provenance_audit.md`
- `harness/reports/security_baseline_audit.md`
- `harness/reports/precommit_baseline_audit.md`
- `harness/state/notifications/last_notification.json`
# Worker 중단과 큐 복구 추가 안내 (2026-10-15)

설치된 대상 루트에서 `pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent <owner>`로 중단된 큐 이동을 조정합니다. 확인된 worker 종료까지 반영하려면 `-AssignmentId <id>`를 추가합니다. 실행 중이거나 종료 여부가 불명확한 worker는 자동으로 재배정하지 않습니다. 이 명령은 프로세스를 죽이지 않습니다.

개발 루트의 자체 검증은 `pwsh -NoProfile -File scripts/test_harness.ps1`이며 새 복구 테스트만 실행하려면 `scripts/test_harness_recovery.ps1`을 사용합니다. CLI 위치를 명시할 때는 `HARNESS_CODEX_PATH`를 사용하고, 테스트 fake 경로를 운영 환경에 남기지 않습니다. 자세한 절차와 제한은 [복구 설계](recovery_design.md)를 확인하세요.

# 실행 사용량 조회 추가 (2026-10-15)

독립 배치: `pwsh -NoProfile -File scripts/get_execution_usage.ps1 [-Json]`.
이식 배치: `pwsh -NoProfile -File harness/scripts/get_execution_usage.ps1 [-Json]`.
한도는 활성 프로필의 선택적 `execution_policy`로 지정합니다. [정책 의미와 불확실한 기록 처리](execution_usage.md)를 먼저 확인하세요. 다음 실행 제한이며 실행 중 강제 종료는 아닙니다.

