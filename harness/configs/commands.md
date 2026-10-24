# Harness Commands

## Read-only web monitor

- `pwsh -NoProfile -File scripts/harness.ps1 dashboard`: local browser monitor (Python 3.9+).
- `dashboard -NoOpen -Port 8768 -RefreshSeconds 10`: explicit port and collection interval; Ctrl+C stops.
- `dashboard -PythonExecutable <path>`: choose native Python explicitly.
- `dashboard -Snapshot -Json`: read once without Python/server, writes or notifications.
- `dashboard -Preview -Json`: preview the fixed command plan without starting anything.
- `pwsh -NoProfile -File scripts/test_harness_dashboard.ps1`: isolated collector/CLI/evidence/security cases.
- `python -B scripts/test_harness_dashboard_server.py`: local HTTP/unit/security tests.

Nested installs use `harness/scripts/harness.ps1`. See [dashboard contract](../docs/dashboard.md).

## Profile-based shell validation

Standalone: `sh scripts/run_unit.sh [--preview]`; nested: `sh harness/scripts/run_unit.sh [--preview]`.
The same applies to run_build.sh, run_integration.sh and run_benchmark_smoke.sh.
Cycle accepts `--skip-retry-prompt`; retry accepts no options. All accept `--help` alone.
Unknown arguments fail with code 2. Tool arguments belong in profile.commands; there is no default make fallback.
Run `pwsh -NoProfile -File scripts/test_harness_shell.ps1` for isolated real Node CLI regressions.
Run `pwsh -NoProfile -File scripts/test_harness_entrypoints.ps1` for caller comparisons: native PowerShell/Bash, plus CMD on Windows. It generates isolated shell fixtures first; `-FixtureDirectory <previous-shell-run-directory>` reuses only a generated test fixture.
The full `test_harness.ps1` automatically reuses its shell fixtures for this comparison.
For focused reruns use `test_harness_shell.ps1 -CasePattern '*relocated*'`; this runs only the selected cases and does not establish a full-suite pass. No matches return exit 1.
See [shell contract](../docs/shell_commands.md) for environment boundaries, runtime requirements and migration.

## Development Checkout Scope

- Claude adapter unit/integration/security tests without paid calls:
  `pwsh -NoProfile -File scripts/test_provider_claude.ps1`
- In a configured target, set `worker_provider` to `{ "version": 1, "name": "claude" }` and use existing run/invoke commands. `HARNESS_CLAUDE_PATH` selects an explicit executable. See [Claude permissions and contract](../docs/claude_adapter.md).

This repository currently has no active target project profile or configured application commands.
Commands below use the installed target-root/harness layout. The make commands are examples, not this repository's build commands.
For the complete implemented script inventory, see `../docs/feature_inventory.md`; for readiness, see `../docs/current_state.md`.
From this checkout, `pwsh -NoProfile -File scripts/init_project_adapter.ps1 -ListPresets` lists supported presets without configuring a target.

User-facing workflow steps and command usage are summarized in `harness/docs/user_actions_and_commands.md`. Keep both files updated when adding, removing, or changing commands.

## Standard Commands

- provider request/result/usage unit, integration and security regressions
  - `pwsh -NoProfile -File scripts/test_provider_contract.ps1`
- inspect recorded provider identity, normalized results and usage
  - `pwsh -NoProfile -File scripts/harness.ps1 usage -Json`

Optional target profile selection is `worker_provider: {version: 1, name: "codex"}` or name `claude`.
Unsupported names are rejected; no provider-switch CLI flag or automatic fallback is added.
See [provider contract](../docs/provider_contract.md).

- unified entry / help (standalone layout)
  - `pwsh -NoProfile -File scripts/harness.ps1 help`
- side-effect-free seed call preview
  - `pwsh -NoProfile -File scripts/harness.ps1 run -PlanFile plans/seed.md -Preview -Json`
- recovery report (no worker launch)
  - `pwsh -NoProfile -File scripts/harness.ps1 resume -PlanFile plans/seed.md -Json`
- explicit recovery execution
  - `pwsh -NoProfile -File scripts/harness.ps1 resume -PlanFile plans/seed.md -Execute`
- categorized CLI unit/integration/security regressions
  - `pwsh -NoProfile -File scripts/test_harness_cli.ps1`

For nested targets prefix the script path with `harness/`. See [CLI](../docs/cli.md)
for init/doctor/status/usage/test, target selection, JSON and exit codes.

- isolated assignment execution evidence regressions (development checkout)
  - `pwsh -NoProfile -File scripts/test_assignment_evidence.ps1`
- complete only after actual assignment validation (configured nested target)
  - `pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <id> -Result pass`
- explicitly revalidate an existing completed pass, preserving evidence history
  - `pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <id> -Result pass -Revalidate`

See [execution evidence](../docs/assignment_evidence.md) for legacy pass handling,
worker exit requirements and snapshot scope. In a standalone target omit `harness/`.

- engine self-test (development checkout; no target profile, AI, or network required)
  - `pwsh -NoProfile -File scripts/test_harness.ps1`
- engine syntax and JSON checks only
  - `pwsh -NoProfile -File scripts/test_harness.ps1 -SyntaxOnly`
- isolated safety regressions only
  - `pwsh -NoProfile -File scripts/test_harness_safety.ps1`
- isolated queue recovery and worker lifetime regressions
  - `pwsh -NoProfile -File scripts/test_harness_recovery.ps1`
- reconcile interrupted queue transitions in an installed target
  - `pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent <owner>`
- reconcile a confirmed worker exit and its completion record
  - `pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent <owner> -AssignmentId <id>`
  - unconfirmed exits remain blocked; this command does not kill processes or force requeue
- Linux/macOS setup
  - `sh harness/scripts/setup_portable_runtime.sh`
- portable platform smoke
  - `sh harness/scripts/run_portable_smoke.sh`
- portable operational smoke
  - `sh harness/scripts/run_operational_smoke.sh`
- portable PR control smoke
  - `sh harness/scripts/run_pr_control_smoke.sh`
- portable GitHub policy smoke
  - `sh harness/scripts/run_github_policy_smoke.sh`
- portable platform engineering smoke
  - `sh harness/scripts/run_platform_engineering_smoke.sh`
- portable security and quality smoke
  - `sh harness/scripts/run_security_quality_smoke.sh`
- create project intake template
  - `pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -CreateTemplate`
- review project intake
  - `pwsh -NoProfile -File harness/scripts/review_project_intake.ps1 -IntakeFile docs/project_intake.md -RequireSeedPlan`
- generate env manifest from intake
  - `pwsh -NoProfile -File harness/scripts/generate_env_manifest.ps1 -IntakeFile docs/project_intake.md`
- start from filled project intake
  - `pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun`
- start while deferring clarification questions
  - `pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun -AllowDeferredClarifications`
- build
  - `make`
- unit
  - `make unit`
- integration
  - `make integration`
- benchmark smoke
  - `make benchmark-smoke`
- release
  - `make`
- full cycle
  - `pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1`
- preflight
  - `pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1`
- audit generated artifacts
  - `pwsh -NoProfile -File harness/scripts/audit_generated_artifacts.ps1`
- audit porting layout
  - `pwsh -NoProfile -File harness/scripts/audit_porting_layout.ps1`
- audit Git remote and GitHub CLI auth
  - `pwsh -NoProfile -File harness/scripts/audit_git_remote_auth.ps1 -CheckGitHubApi`
- bootstrap initial commit dry run
  - `pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -DryRun`
- bootstrap initial commit
  - `pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -Commit -RequestApproval`
- install reproducible dev environment
  - `pwsh -NoProfile -File harness/scripts/install_dev_environment.ps1 -Force`
- audit reproducible dev environment
  - `pwsh -NoProfile -File harness/scripts/audit_dev_environment.ps1`
- install service contract
  - `pwsh -NoProfile -File harness/scripts/install_service_contract.ps1 -Preset postgres-redis -Force`
- audit service contract
  - `pwsh -NoProfile -File harness/scripts/audit_service_contract.ps1`
- start service contract
  - `pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action up`
- stop service contract
  - `pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action down`
- audit CI matrix and cache
  - `pwsh -NoProfile -File harness/scripts/audit_ci_matrix.ps1`
- install release provenance workflow
  - `pwsh -NoProfile -File harness/scripts/install_release_provenance_workflow.ps1 -Force`
- audit release provenance workflow
  - `pwsh -NoProfile -File harness/scripts/audit_release_provenance.ps1`
- install security baseline
  - `pwsh -NoProfile -File harness/scripts/install_security_baseline.ps1 -Force`
- audit security baseline
  - `pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1`
- audit GitHub security settings
  - `pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1 -CheckGitHubSecuritySettings`
- install pre-commit baseline
  - `pwsh -NoProfile -File harness/scripts/install_precommit_baseline.ps1 -Force`
- audit pre-commit baseline
  - `pwsh -NoProfile -File harness/scripts/audit_precommit_baseline.ps1`
- harness status snapshot
  - `pwsh -NoProfile -File harness/scripts/get_harness_status.ps1`
- telegram notification dry run
  - `pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -DryRun -Force -Message "Harness notification test" -Provider telegram`
- telegram notification force send
  - `pwsh -NoProfile -File harness/scripts/send_harness_notification.ps1 -Force -Message "Harness notification test" -Provider telegram`
- seed handoff resume report
  - `pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md`
- resume live seed handoff
  - `pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile harness/reports/seed_plans/<plan-file>.md`
- retry prompt generation
  - `pwsh -NoProfile -File harness/scripts/generate_retry_prompt.ps1`
- retry prompt dispatch
  - `pwsh -NoProfile -File harness/scripts/dispatch_retry_prompt.ps1`
- assignment claim
  - `pwsh -NoProfile -File harness/scripts/claim_assignment.ps1 -Agent <owner> -AssignmentId <assignment-id>`
- assignment complete
  - `pwsh -NoProfile -File harness/scripts/complete_assignment.ps1 -Agent <owner> -AssignmentId <assignment-id> -Result pass`

## Git Workflow Commands

- install hooks
  - `pwsh -NoProfile -File harness/scripts/install_git_hooks.ps1`
- feature gate (before pushing `<owner>/<task>`; add `-AllowCommittedHead` for a committed head)
  - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature`
- engine repository self gate (used by `.harness/self_workflow.json`; `-Stage feature|integration|final`)
  - `pwsh -NoProfile -File scripts/run_self_gate.ps1 -Stage integration`
- integration gate
  - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage integration`
- final gate
  - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage final`
- bootstrap gate
  - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage bootstrap`
- approve deleting an unmerged remote feature/test branch (then `git push origin --delete <branch>`)
  - `pwsh -NoProfile -File harness/scripts/approve_branch_deletion.ps1 -Branch <branch> -Approver <name> -Reason <why>`
- git workflow audit
  - `pwsh -NoProfile -File harness/scripts/audit_git_workflow.ps1`
- authorize feature to dev
  - `pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <feature-branch> -TargetBranch dev`
- merge authorized feature to dev
  - `pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <feature-branch> -TargetBranch dev`
- request main approval
  - `pwsh -NoProfile -File harness/scripts/request_main_merge_approval.ps1 -SourceBranch <test-branch>`
- record main approval
  - `pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId <approval-id> -Status approved -Approver <name>`
- authorize test to main
  - `pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <test-branch> -TargetBranch main -ApprovalId <approval-id>`
- merge authorized test to main
  - `pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <test-branch> -TargetBranch main`
- install GitHub Actions harness workflow
  - `pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1`
- audit GitHub server policy
  - `pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1`
- install or update GitHub server ruleset
  - `pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1`
- protect dev from deletion and force push (no PR/check rules)
  - `pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1 -Branch dev -ProtectionOnly`
  - audit: `pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1 -Branch dev -ProtectionOnly`
- open PR candidate for main
  - `pwsh -NoProfile -File harness/scripts/open_pr_candidate.ps1 -SourceBranch <test-branch>`
- check PR gate status
  - `pwsh -NoProfile -File harness/scripts/check_pr_status.ps1 -PullRequest <pr-number-or-branch>`
- merge PR after local approval and required checks
  - `pwsh -NoProfile -File harness/scripts/merge_pr_if_allowed.ps1 -PullRequest <pr-number-or-branch> -ApprovalId <approval-id>`

## Actual Handoff

- invoke assigned owner with Codex
  - `pwsh -NoProfile -File harness/scripts/invoke_assignment_codex.ps1 -Agent <owner> -AssignmentId <assignment-id>`
- invoke oldest pending assignment for an owner
  - `pwsh -NoProfile -File harness/scripts/invoke_pending_assignment_codex.ps1 -Agent <owner>`
- full retry handoff
  - `pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1`
- retry handoff dry run
  - `pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1 -DryRun`
- retry handoff preflight
  - `pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1 -PreflightOnly`
- explicit prompt dispatch
  - `pwsh -NoProfile -File harness/scripts/dispatch_retry_prompt.ps1 -PromptId <prompt-id>`

## Notes

- `dispatch_retry_prompt.ps1` dispatches only prompts that match the latest failing cycle unless `-PromptId` is given.
- `run_harness_cycle.ps1` generates a retry prompt automatically when the cycle fails.
- use `run_harness_cycle.ps1 -SkipRetryPrompt` only for nested validation to avoid recursive retry generation.
- `invoke_assignment_codex.ps1 -DryRun` writes the prompt and readiness files without starting `codex exec`.
- `invoke_assignment_codex.ps1 -PreflightOnly` checks packet availability and local Codex CLI readiness without claiming or completing the assignment.
- live execution summaries are written to `harness/reports/agent_runs/`.
- live dispatch events are appended to `harness/reports/live_dispatch_log.md`.
- seed handoff resume reports are written to `harness/reports/seed_plans/<plan-id>__resume.md` and `.json`.
- Telegram notifications are sent by `send_harness_notification.ps1` when `HARNESS_NOTIFY_PROVIDER=telegram`, `HARNESS_TELEGRAM_BOT_TOKEN`, and `HARNESS_TELEGRAM_CHAT_ID` are set.
- notification events are logged to `harness/reports/notifications_log.md`; duplicate signatures are tracked under `harness/state/notifications/`.
- build/test and owner validation defaults come from `harness/project/configs/project_profile.json`.
- new-project defaults can be generated from `init_project_adapter.ps1 -Language <language> -Framework <framework>`.
- requirements-only setup can use `init_project_adapter.ps1 -RequirementsFile <brief.md> -Interactive` to infer or ask for the target environment.
- one-file setup can use `start_from_intake.ps1` after filling `docs/project_intake.md`; it runs intake review first unless `-SkipIntakeReview` is passed.
- intake startup generates `docs/env_manifest.md`, `.env.example`, and `harness/reports/sensitive_followups.md` from safe intake sections.
- real private token, password, and API key values stay outside Git; the harness records names and local/mock setup only.
- failure classification patterns also come from `harness/project/configs/project_profile.json`.
- status snapshots mark `secret`, `requirements`, and `environment` failures as user-action items instead of blindly retrying them.
- cumulative suite history is written to `harness/reports/test_results/`.
- path and harness output settings must stay inside the repository root or preflight will fail.
- generated harness reports/state/assignment queues must stay ignored; staged generated artifacts are reported by `audit_generated_artifacts.ps1`.
- first protected baseline commits can be planned with `bootstrap_initial_commit.ps1 -DryRun` before running the real bootstrap gate and commit.
- Git push/fetch credentials and GitHub CLI credentials are separate; use `audit_git_remote_auth.ps1` before PR or ruleset automation.
- seed dry-run can package assignments before the first Git commit; live worker dispatch requires an existing Git baseline commit on the configured base branch.
- `run_seed_handoff.ps1 -Resume` skips passed seed assignments, requeues failed ones with previous failure analysis, and does not start a second worker when an invoke lock is active.
- Git workflow is hook-backed and stateful; see `harness/configs/git_policy.md`.
- `pre-push` validates the actual ref updates, so `HEAD:main` or `feature:dev` style refspec bypasses are blocked.
- `pre-rebase` blocks history rewrites on protected branches.
- Git gates reject no-op or failure-masking validation commands such as `true`, `exit 0`, or `|| true`.
- Hybrid PR control uses GitHub CLI `gh`; authenticate once with `gh auth login` or set `HARNESS_GH_PATH` when `gh` is not on `PATH`.
- GitHub server policy control uses repository rulesets through `gh api`; the authenticated account must have repository administration permission.
- Dev environment, service contract, CI matrix/cache, and release provenance setup are generated from `harness/project/configs/project_profile.json`.
- Security baseline and pre-commit setup are generated from `harness/project/configs/project_profile.json`.
# Execution usage (2026-10-15)

- Standalone: `pwsh -NoProfile -File scripts/get_execution_usage.ps1 [-Json]`
- Installed: `pwsh -NoProfile -File harness/scripts/get_execution_usage.ps1 [-Json]`
- Optional `execution_policy` in the active profile controls launch count, assignment attempts, concurrency and subsequent-launch token/time thresholds. See `docs/execution_usage.md`; no provider quota or monetary amount is inferred.

