# AGENT.md for Harness Improvement

## Development Checkout

This repository develops the reusable Harness engine. It has no active target project profile.
Consult docs/feature_inventory.md (including its implementation boundaries) and docs/improvement_backlog.md as needed before planning changes.
Paths beginning with harness/ below describe the installed layout in a target repository.
Do not treat the current checkout as configured for live dispatch or a passing full cycle.

## Purpose

`harness/` is the operations layer for this repository.

It is responsible for:

- build and test orchestration
- benchmark smoke execution
- failure classification
- retry prompt generation
- assignment dispatch and completion
- live or preview Codex handoff
- Git workflow gating
- optional hybrid GitHub PR control for the final `main` merge
- optional GitHub repository ruleset audit and installation
- reproducible development environment generation
- service dependency contracts for local and CI execution
- CI matrix/cache policy generation
- release provenance workflow generation
- security baseline generation and audit
- pre-commit quality baseline generation and audit

The harness is not product code. Its job is to keep the execution loop safe, observable, and repeatable.

## Directory Layout

```text
harness/
  AGENT.md
  assignments/
  prompts/
  scripts/
  reports/
  configs/
  state/
```

## Baseline Requirements

The harness baseline is considered complete only when all of the following are present:

1. A single source of truth in `harness/project/configs/project_profile.json`
2. A working validation pipeline for build, unit, integration, benchmark smoke, and full cycle
3. A failure model that classifies and records the next owner and task
4. Retry generation plus dispatch into assignment queues
5. A safe assignment lifecycle of `inbox -> in_progress -> done`
6. Path, write, encoding, and permission safety checks
7. Gated Git workflow rules for commit, push, merge, and promotion
8. Repository hygiene files such as `.gitignore` and `.gitattributes`
9. Operational proof through preflight, cycle, test-result records, and handoff artifacts

See `harness/configs/harness_checklist.md` for the detailed checklist.

When adding or changing user-visible workflow steps or commands, update `harness/docs/user_actions_and_commands.md` in the same change. If the command list changes, update `harness/configs/commands.md` as well.

## Main Responsibilities

- Keep the validation order fixed: build -> unit -> integration -> benchmark smoke
- Record the latest pass or fail result in `harness/reports/latest_report.md`
- Write per-suite evidence under `harness/reports/test_results/`
- Generate retry prompts for failing cycles unless explicitly skipped
- Accept a structured manager-main seed plan and convert it into assignment queues
- Convert prompts into assignments and dispatch packets
- Track live handoff results in `harness/reports/agent_runs/` and `harness/reports/live_dispatch_log.md`
- Enforce the local Git workflow described in `harness/configs/git_policy.md`
- Use GitHub PR control scripts for `main` only after the local final gate and approval have passed
- Keep GitHub server policy audit/install aligned with the local Git workflow when hybrid PR control is used
- Keep devcontainer, service contract, CI matrix/cache, and release provenance files generated from the active project profile
- Keep Dependabot, CodeQL, OpenSSF Scorecard, and pre-commit baseline generated from the active project profile

## Failure Types

- `compile`
- `interface`
- `logic`
- `missing-test`
- `environment`

## Current Guarantees

- individual validation shell entries and cycle share profile command resolution; no implicit make fallback or ignored unknown shell arguments
- shell entries bind to their installed project and reject conflicting inherited root/workspace values; recursive validation is refused
- preserve the real CLI fixture regression in `scripts/test_harness_shell.ps1`; see `docs/shell_commands.md` for the command contract and platform limits

- locks use an exclusive OS file handle; elapsed time never overrides an active owner
- acquire returns a lease object; pass that same object to release/update (old leases cannot release a new owner)
- legacy lock directories without a lease file fail closed and require an operator to confirm all old workers have stopped before cleanup
- approval checks bind repository root, source branch/head, target branch, and approval stage
- workflow state writes reject stale snapshots instead of overwriting another writer's approvals
- self-tests run without an active project profile: `pwsh -NoProfile -File scripts/test_harness.ps1`
- duplicate pending dispatch for the same `prompt_id` is blocked
- assignment lifecycle is `inbox -> in_progress -> done`
- `complete_assignment -Result pass` executes the assignment validation and binds code, Git state, log, assignment and invocation evidence; never trust a pass marker alone
- recheck evidence after worker exit and before promotion; final feature commits require explicit revalidation, as described in `docs/assignment_evidence.md`
- assignment state files are rewritten in UTF-8
- target creation succeeds before source removal during assignment transitions
- assignment transitions use an owner queue lease and a durable journal; pending transitions are reconciled before the next mutation, while conflicting content fails closed
- profile-driven owner mappings, commands, and failure patterns are read from `harness/project/configs/project_profile.json`
- `run_harness_preflight.ps1` blocks harness paths and owner paths that escape the repository root
- harness report and state paths are write-tested during preflight
- cumulative suite records are written under `harness/reports/test_results/`
- failed harness cycles generate a retry prompt unless explicitly skipped
- live assignment execution uses a per-assignment feature branch target
- stale `in_progress` assignments are recovered only while holding their invoke lease and only without unresolved worker evidence
- worker launch intent is durable before spawn; a separate worker host holds its own lease and logs without depending on its parent
- an unconfirmed worker exit blocks retry and seed promotion even when the parent invoke lease has disappeared; see `docs/recovery_design.md`
- standalone/nested engine paths use `harness_layout.ps1`; preserve arbitrary project requirement text when generating layout-specific instructions
- every new worker intent reserves an invocation under the project execution_budget lease; unknown usage is never treated as zero
- token/time policy thresholds block subsequent launches, not running processes; preserve unresolved reservations and see `docs/execution_usage.md`
- provider launch/response/usage decoding belongs in adapters; preserve the versioned request/result contract described in `docs/provider_contract.md`
- never fall back from an unsupported provider; explicit provider failure events invalidate success even when process exit is zero
- Claude print mode requires a valid final result; incomplete output fails closed. Preserve acceptEdits/denied prompts and never grant unrestricted Bash to make a test pass; see `docs/claude_adapter.md`

## Primary Entry Points

- unified command entry: `scripts/harness.ps1 help`; see `docs/cli.md`
- preserve the distinction between side-effect-free `-Preview` and the existing seed `-DryRun`, which can install hooks/write reports
- CLI query success means the query completed; never interpret it as a project validation pass

Start here depending on the task:

- current validation state: `reports/preflight_report.md`, `reports/latest_report.md`, `reports/test_results/`
- project retargeting: `docs/PORTING.md`, `configs/project_profile.template.json`
- implemented feature inventory: `docs/feature_inventory.md`
- user actions and commands: `docs/user_actions_and_commands.md`
- script usage: `scripts/README.md`
- Git workflow safety: `configs/git_policy.md`

## Live Handoff

- `run_retry_handoff.ps1` is the single entry point from retry prompt generation to dispatch and worker invocation
- assignment branches start from `dev` when it exists; each passing assignment is promoted into `dev` before the next one starts, and its merged worktree/branch is removed unless `-KeepMergedAssignmentBranches` is set
- `run_seed_handoff.ps1` is the single entry point from a manager-main seed plan to serial worker invocation, retry, and automatic promotion up to a main approval request
- `invoke_assignment_codex.ps1` executes a claimed assignment through the configured Codex or Claude adapter; its filename is retained for compatibility
- `invoke_pending_assignment_codex.ps1` selects the oldest pending assignment for an owner
- `-DryRun` writes preview artifacts without starting Codex
- `-PreflightOnly` verifies readiness and writes summary artifacts without execution
- live execution uses an isolated assignment worktree under `harness/state/worktrees` and runs on the expected assignment feature branch inside that worktree
- live seed execution retries failed assignments up to the configured limit and can continue to later assignments without operator input
- when every assignment passes, seed execution can automatically promote through `dev`, run the final gate on a `test/*` branch, and request `main` approval
- seed execution must not approve or merge `main`; that remains a manual final-manager action

## Git Workflow Safety

Harness treats Git promotion as an enforced workflow, not a note in documentation.

Rules:

- feature work happens on `<owner>/<task>`; commits there are not gated, but pushing requires a passing feature gate for the head tree
- direct commits to `dev`, `main`, and `test/*` are blocked by local hooks
- merged feature/test branches may be deleted remotely; unmerged ones only after the user records `approve_branch_deletion.ps1` for that head; `dev`/`main` deletion is blocked
- a feature branch must pass `run_git_gate.ps1 -Stage feature` before commit and push
- a feature branch must pass `run_git_gate.ps1 -Stage integration` before promotion into `dev`
- a dedicated `test/<candidate>` branch must pass `run_git_gate.ps1 -Stage final` before main approval
- `request_main_merge_approval.ps1` and `set_main_merge_approval.ps1` record the approval step for `main`
- `authorize_branch_promotion.ps1` records the exact source-head authorization required by protected merges
- manual protected merges must use `merge_authorized_branch.ps1` so the merge hook receives the intended source branch and source head
- hybrid PR merges must use `open_pr_candidate.ps1`, `check_pr_status.ps1`, and `merge_pr_if_allowed.ps1`
- PR merge control requires GitHub CLI, an open non-draft PR from the approved `test/*` head to `main`, and passing required checks
- GitHub ruleset control must use `install_github_ruleset.ps1` and `audit_github_policy.ps1`
- the default server ruleset blocks delete and force-push, requires PRs, requires one approving review, and requires strict `Harness CI`
- platform engineering changes must keep `Harness CI` as the required-check aggregator even when matrix jobs are added
- pre-commit must remain a lightweight quality layer; harness Git hooks remain authoritative for Git governance
- `install_git_hooks.ps1` must keep `core.hooksPath` aligned with the repository's absolute `.githooks` path so isolated worktrees use the shared hooks
- `pre-push` validates actual ref updates and rejects refspec bypasses into protected branches
- `pre-rebase` blocks rebases on protected branches
- `audit_git_workflow.ps1` should pass before trusting the current protected branch state

Use `harness/configs/git_policy.md` for the full promotion flow.
