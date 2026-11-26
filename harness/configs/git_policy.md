# Git Workflow Policy

## Goal

Protect commit, push, and merge operations so only a tested tree can move through the workflow.

## Protected Flow

1. Work on a feature branch named `<owner>/<task>` (`git_workflow.feature_branch_prefix` is empty by default; `<owner>` must be listed in `owners`).
   - live harness assignment branches are created from the repository baseline branch, not from whichever branch happens to be checked out
   - commits on working branches are not gated; evidence is required when work leaves the branch (push, dev merge, main merge)
   - automatic seed promotion merges into whichever worktree has `dev` checked out (the main checkout when it is on `dev`). That worktree must be clean; a live seed run checks this before starting any worker
   - harness assignment branches start from `dev` once it exists (from `main` before the first promotion). Seed runs promote each passing assignment into `dev` immediately so serial assignments build on each other
2. Commit as often as needed. Before pushing, keep the candidate sealed: no unstaged files, no untracked files, no merge conflicts.
3. Run the owner gate on the candidate:
   - committed head: `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature -AllowCommittedHead`
   - staged tree (commit after the gate): `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage feature`
4. Push the feature branch. The push hook requires a passing feature gate for the exact head tree.
5. Run the manager integration gate on the same feature branch:
   - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage integration`
6. Authorize promotion into `dev`:
   - `pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <feature-branch> -TargetBranch dev`
7. Merge into `dev` through the authorized merge wrapper:
   - `pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <feature-branch> -TargetBranch dev`
8. Create a dedicated final test branch named `test/<candidate>` from `dev`.
9. Run the final full-cycle gate:
   - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage final`
10. Request main merge approval:
    - `pwsh -NoProfile -File harness/scripts/request_main_merge_approval.ps1 -SourceBranch <test-branch>`
11. Record the approval or rejection:
    - `pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId <id> -Status approved -Approver <name>`
12. Choose one protected `main` merge path.
13. Local-only path: authorize promotion into `main`:
    - `pwsh -NoProfile -File harness/scripts/authorize_branch_promotion.ps1 -SourceBranch <test-branch> -TargetBranch main -ApprovalId <id>`
14. Local-only path: merge into `main` through the authorized merge wrapper:
    - `pwsh -NoProfile -File harness/scripts/merge_authorized_branch.ps1 -SourceBranch <test-branch> -TargetBranch main`
    The protected merge and push hooks enforce the authorization and approval.
15. Hybrid PR path: create or refresh the GitHub Actions workflow, open the PR, wait for required checks, then merge through the PR wrapper:
    - `pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1`
    - `pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1`
    - `pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1`
    - `pwsh -NoProfile -File harness/scripts/open_pr_candidate.ps1 -SourceBranch <test-branch>`
    - `pwsh -NoProfile -File harness/scripts/check_pr_status.ps1 -PullRequest <pr-number-or-branch>`
    - `pwsh -NoProfile -File harness/scripts/merge_pr_if_allowed.ps1 -PullRequest <pr-number-or-branch> -ApprovalId <id>`
    The PR wrapper rechecks local approval, exact source head, final gate, and required GitHub checks before calling `gh pr merge --match-head-commit`.

## Bootstrap Rule

The first protected commit on `main` is special because this repository currently has no `HEAD`.

Bootstrap flow:

1. Stage the initial baseline.
2. Run:
   - `pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage bootstrap`
3. Commit on `main`.
4. Request approval:
   - `pwsh -NoProfile -File harness/scripts/request_main_merge_approval.ps1 -Bootstrap`
5. Record approval:
   - `pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId <id> -Status approved -Approver <name>`
6. Push `main`.

## Hard Rules

- Do not commit directly on `dev`.
- Do not commit directly on `main`.
- Do not commit directly on `test/*`.
- Commits on other local branches are allowed without a gate.
- Do not push a feature branch unless the current `HEAD` tree matches a passing `feature` gate.
- Do not push branches whose names are outside the workflow (`main`, `dev`, `<owner>/<task>`, `test/<candidate>`).
- Do not delete remote `main` or `dev`.
- A remote feature or test branch may be deleted when its remote head is contained in `dev` or `main`, or when the user recorded a deletion approval for that exact head (abandoned or restarted work):
  - `pwsh -NoProfile -File harness/scripts/approve_branch_deletion.ps1 -Branch <branch> -Approver <name> -Reason <why>`
  - then `git push origin --delete <branch>`
- The user can also delete a non-protected branch directly in the GitHub web UI; local hooks do not run there.
- Do not push a test branch unless the current `HEAD` tree matches a passing `final` gate.
- Do not merge into `dev` unless `feature` and `integration` gates passed for the exact source head.
- Do not merge into `main` unless `final` passed, approval is `approved`, and the source head was explicitly authorized.
- Do not merge a GitHub PR into `main` unless the PR source is the exact approved `test/*` head and required PR checks are passing.
- Do not use destructive Git commands from harness automation.
- Do not revert unrelated user changes.

## Enforcement

- `.githooks/pre-commit` blocks direct commits on `main`, `dev`, and `test/*` (except the first bootstrap commit flow).
- `.githooks/pre-push` blocks pushes that do not satisfy the gate and promotion rules, remote deletion of `main`/`dev`, and deletion of unmerged branches without a recorded user approval.
- `.githooks/pre-merge-commit` blocks protected merges without promotion authorization. Use `merge_authorized_branch.ps1` for manual protected merges so the hook receives the intended source branch and source head.
- `.githooks/pre-rebase` blocks rebases on protected branches.
- `run_git_gate.ps1` rejects no-op or failure-masking validation commands such as `true`, `exit 0`, or `|| true`.
- `open_pr_candidate.ps1` refuses to open a main PR unless the source is a dedicated `test/*` branch with a passing final gate for the exact tree.
- `run_git_gate.ps1` takes stage commands only from configuration (`owners.<owner>.validation`, `commands.integration`, `commands.full_cycle`). There is no `make` or `pwsh` fallback; a missing command fails closed.
- The engine repository itself has no project profile; its Git policy (owners and gate commands) is `.harness/self_workflow.json`, used only when no profile exists and the engine is at the repository root. Its gates run `scripts/run_self_gate.ps1`.
- `check_pr_status.ps1` reads required PR checks through GitHub CLI.
- `merge_pr_if_allowed.ps1` refuses draft, non-main, non-test-branch, stale-head, unapproved, or failing-check PRs before calling `gh pr merge --match-head-commit`.
- `install_github_actions_workflow.ps1` writes a minimal GitHub Actions workflow that runs portable setup and the full harness cycle in CI mode.
- `install_github_ruleset.ps1` creates or updates the harness-owned GitHub repository ruleset for protected `main`.
- `install_github_ruleset.ps1 -Branch dev -ProtectionOnly` adds a separate `dev` ruleset with deletion and force-push protection only. `dev` is updated by locally authorized merges, so it does not require PRs or status checks. `-ProtectionOnly` is refused for `main`.
- `audit_github_policy.ps1` verifies that an active ruleset protects `main` with PR-only updates, delete and force-push protection, strict required checks, and the configured review count.
- On Linux/macOS, harness shell validation runs with `bash -e -o pipefail` when Bash is available so failed commands inside pipelines are not treated as passing.
- `harness/scripts/install_git_hooks.ps1` installs `core.hooksPath` as the repository's absolute `.githooks` path so isolated worktrees always use the shared hooks.
- `harness/scripts/run_harness_preflight.ps1` fails when the hook path, Git workflow files, or current protected branch state are invalid.
- `harness/scripts/audit_git_workflow.ps1` audits the current branch head against the recorded gate, promotion, and approval state.

## Limits

This policy is strong locally, but not perfect:

- `git commit --no-verify` or `git push --no-verify` can bypass local hooks.
- Server-side branch protection or rulesets must still be configured in GitHub when the repository requires server-enforced PR-only merges.
- Approval is recorded locally, not in a remote review system.
- GitHub CLI must be installed and authenticated before the PR wrapper scripts can access PR state.
- The GitHub Actions workflow and required-check policy must exist on the protected GitHub repository before relying on the hybrid PR path for enforcement.
- Installing or updating GitHub rulesets requires repository administration permission for the authenticated `gh` account.

## Remaining Manual Controls

- do not use custom refspec pushes to target protected branches outside the documented promotion flow
- do not rewrite protected branch history with low-level Git commands
- if a hook was bypassed, run `audit_git_workflow.ps1` and fix the branch before the next merge or push
- if using hybrid PR control, configure required checks in GitHub so `gh pr checks --required` has a server-side policy to evaluate
- install and merge `.github/workflows/harness-ci.yml` before making it the required check for protected `main`
