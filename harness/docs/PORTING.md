# Harness Porting Guide

## What Porting Means

Porting means copying this `harness/` directory into another repository root and retargeting its project adapter so the same validation, assignment, subagent handoff, retry, report, and Git gate workflow works for that repository.

The expected layout after copying is:

```text
<target-repo>/
  harness/
    scripts/
    configs/
    project/
    docs/
    githooks/
```

For this nested layout, the repository root is the parent of `harness/`. Core PowerShell and validation/cycle/retry shell entries also support a standalone engine at the repository root. See [layout support](layout_support.md) and the [shell contract](shell_commands.md) for supported paths, profile requirements and migration.

When upgrading, stop and confirm old workers before replacing the engine scripts together. Existing assignment pass records without execution evidence become unverified. Do not copy runtime evidence to certify another checkout: it binds repository/workspace paths and Git/source state. Inspect the assignment validation and confirmed worker exit, then explicitly revalidate as described in [assignment evidence](assignment_evidence.md).

For the user-facing action list and command index, keep `harness/docs/user_actions_and_commands.md` current.

## Minimal Porting Flow

1. Copy `harness/` into the target repository root.
2. From the target root, initialize the adapter. Use `pwsh` on Linux/macOS, WSL, or Windows with PowerShell 7; use `powershell.exe` only as the native Windows fallback:

```powershell
pwsh -NoProfile -File harness/scripts/init_project_adapter.ps1 -ProjectName <name> -Language <language> -Framework <framework> -Force
```

   The adapter merges missing harness rules into an existing `.gitignore`/`.gitattributes` (framework generators usually create them) instead of skipping the file. For Java/Kotlin it uses the checked-in Gradle or Maven wrapper with an explicit path (`.\gradlew.bat` on Windows, `./gradlew` elsewhere) and the `src/main/java`, `src/main/resources`, `src/test` layout.
3. Review `harness/project/configs/project_profile.json`.
4. Review the root docs and hygiene files seeded by the adapter:
   - `AGENT.md`
   - `docs/requirements.md`
   - `docs/requirements_raw_links.md`
   - `docs/env_manifest.md`
   - `docs/subagent_plan.md`
   - `docs/subagent_first_prompts.md`
   - `.gitignore`
   - `.gitattributes`
5. Install hooks and run validation. If you passed `-RunPreflight` to `init_project_adapter.ps1`, hook installation and preflight have already run once:

```powershell
pwsh -NoProfile -File harness/scripts/install_git_hooks.ps1
pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1
pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1 -SkipRetryPrompt
```

On Linux/macOS, this helper normalizes shell executable bits, installs Git hooks, and runs preflight:

```sh
sh harness/scripts/setup_portable_runtime.sh
```

Shell wrappers and Git hooks prepare writable PowerShell XDG cache/data/config directories outside the repository under `${TMPDIR:-/tmp}/codex-harness-xdg/`. Override `CODEX_HARNESS_XDG_ROOT` only when that temp location is not acceptable.

Git hook path conversion is centralized in `harness/scripts/path_common.sh`. Windows paths are converted for POSIX shells only when they are actually Windows paths; existing WSL/POSIX paths such as `/mnt/c/...` are not passed through `wslpath -u` again.

Before the first commit in a newly ported repository, inspect the bootstrap plan:

```powershell
pwsh -NoProfile -File harness/scripts/bootstrap_initial_commit.ps1 -DryRun
```

Use these audits when porting feels wrong or generated files appear in `git status`:

```powershell
pwsh -NoProfile -File harness/scripts/audit_porting_layout.ps1
pwsh -NoProfile -File harness/scripts/audit_generated_artifacts.ps1
pwsh -NoProfile -File harness/scripts/audit_git_remote_auth.ps1 -CheckGitHubApi
```

Before copying into a real target repository, you can run the smoke tests from this harness checkout on Linux or macOS. The portable smoke creates a temporary Git repository, copies `harness/` into it, runs adapter initialization with `pwsh`, runs `setup_portable_runtime.sh`, and verifies the installed hooks:

```sh
sh scripts/run_portable_smoke.sh
```

The operational smoke uses a fake `codex` executable in a temporary repository to verify retry handoff, assignment lifecycle, live worker auto-fail behavior, seed dry-run, and seed live pass behavior without needing a real target application:

```sh
sh scripts/run_operational_smoke.sh
```

The Git hook smoke verifies the protected commit, push, and authorized merge paths in a temporary repository:

```sh
sh scripts/run_git_hook_smoke.sh
```

The PR control smoke uses a fake `gh` executable in a temporary repository to verify hybrid PR open, check status, and guarded merge behavior without contacting GitHub:

```sh
sh scripts/run_pr_control_smoke.sh
```

The GitHub policy smoke uses a fake `gh api` implementation to verify ruleset audit/install behavior without contacting GitHub:

```sh
sh scripts/run_github_policy_smoke.sh
```

The platform engineering smoke verifies generated devcontainer/toolchain manifest, service contract, CI matrix/cache workflow, and release provenance workflow in a temporary repository:

```sh
sh scripts/run_platform_engineering_smoke.sh
```

The security and quality smoke verifies Dependabot, CodeQL, OpenSSF Scorecard, GitHub security setting audit, and pre-commit baseline behavior in a temporary repository:

```sh
sh scripts/run_security_quality_smoke.sh
```

For a real GitHub repository, install the harness Actions workflow after adapter setup:

```powershell
pwsh -NoProfile -File harness/scripts/install_github_actions_workflow.ps1
pwsh -NoProfile -File harness/scripts/install_github_ruleset.ps1
pwsh -NoProfile -File harness/scripts/audit_github_policy.ps1
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
```

## Git Hooks

`harness/githooks/` is the portable hook template set. `install_git_hooks.ps1` installs these files into the target root's configured hook directory, normally `.githooks`, and then sets local `core.hooksPath`. The hooks resolve PowerShell through `harness/scripts/resolve_powershell.sh`, preferring an explicit `CODEX_HARNESS_PWSH`, then `pwsh` on `PATH`, then common user-local PowerShell paths, and falling back to Windows PowerShell only for native Windows shells. WSL and Linux require native `pwsh`. The hooks also use `harness/scripts/powershell_env.sh` so PowerShell runtime cache files do not dirty the repository before Git gates inspect the tree.

Required hook templates:

- `harness/githooks/pre-commit`
- `harness/githooks/pre-push`
- `harness/githooks/pre-merge-commit`
- `harness/githooks/pre-rebase`

## Adapter Files

Project-specific files live under `harness/project/`:

- `harness/project/configs/project_profile.json`
- `harness/project/prompts/manager_main.md`
- `harness/project/prompts/manager_main_seed.md`
- `harness/project/prompts/manager_harness.md`

These are intentionally rewritten per target repository. The reusable engine is in `harness/scripts`, `harness/configs`, `harness/githooks`, and these docs.

## Verification Levels

- Preflight only: hook paths, profile shape, owner paths, writable report paths, and command availability are valid.
- Full cycle: build, unit, integration, benchmark smoke, and report writing all pass.
- Dry-run handoff: assignment dispatch and Codex prompt packaging are valid without launching a worker.
- Operational smoke: retry, assignment, seed, and fake live Codex paths pass without a real target application.
- PR control smoke: local final gate, local approval, required PR checks, and guarded PR merge control are wired together without needing GitHub network access.
- GitHub policy smoke: server ruleset audit/install behavior is wired together without needing GitHub network access.
- Platform engineering smoke: dev environment, service contract, CI matrix/cache, and release provenance generation are wired together without needing network access.
- Security and quality smoke: Dependabot, CodeQL, OpenSSF Scorecard, GitHub security setting audit, and pre-commit baseline generation are wired together without needing network access.
- Live handoff: a real worker assignment runs in an isolated worktree and records a pass/fail summary.

A repository is not fully ported until at least preflight and one full cycle pass in the target repository. If the repository will use hybrid PR control, GitHub CLI authentication and GitHub branch protection or rulesets should also be configured in the target repository. Install and merge `.github/workflows/harness-ci.yml` before relying on it as a required check for protected `main`. Installing the harness ruleset requires repository administration permission.

## Intake-First Flow

If you want the user to fill one file and let the harness start from it, create the intake template from the target repository root:

```powershell
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -CreateTemplate
```

Fill `docs/project_intake.md`, then run:

```powershell
pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun
```

The intake flow first reviews the filled intake. By default it stops when requirements are missing, ambiguous, likely to need external access, or likely to cause avoidable worker retries. The review writes `docs/project_intake_questions.md` and `harness/reports/intake_review_report.md`; update the intake with answers, then rerun. To start anyway and let workers ask later, pass `-AllowDeferredClarifications` or set `clarification_mode: defer_allowed` in the intake.

For external dependencies, fill safe setup details before development starts: provider choice, local/mock strategy, sample data, public endpoints, and environment variable names. Do not paste real private tokens, passwords, or personal credentials into intake; the review records those as sensitive follow-ups for later environment setup.

The intake review also records Git baseline readiness. Seed dry-run can still run before the first commit, but live worker dispatch is marked `needed_before_live` until the target repository has a committed `HEAD`.

After review passes or is deferred, the intake flow runs adapter initialization, applies command overrides, updates requirements/source docs when forced, refreshes generated profile docs, generates `docs/env_manifest.md`, writes an empty `.env.example`, and creates a seed plan when one or more `## Seed Assignment` blocks are filled. `-RunSeedDryRun` verifies that the seed assignments can be packaged for workers without launching live Codex execution, including in an unborn Git repository.

`docs/env_manifest.md` records environment variable names, prepared data, external dependencies, and safe local/mock strategy. `harness/reports/sensitive_followups.md` records private access needs that must be handled later outside Git.

Live worker dispatch still needs an existing Git baseline commit on the configured base branch because live execution creates isolated assignment worktrees.

Live seed handoff means `run_seed_handoff.ps1` takes a seed plan, creates assignment files and dispatch packets, invokes real Codex workers, runs each assignment in an isolated Git worktree on an assignment feature branch, records pass/fail summaries, and optionally advances passing work through the configured Git workflow. Failed live workers are requeued up to the configured retry limit; each retry packet includes the previous worker output as `Previous Failure Analysis` so the next attempt can analyze the failure and make a focused correction.

To inspect or resume an interrupted live seed handoff, run:

```powershell
pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md
pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile harness/reports/seed_plans/<plan-file>.md
```

The resume report shows which seed assignments passed, are pending, are actively running, failed, are missing, or can be recovered from stale `in_progress`. Resume mode skips passed work, reuses pending work, requeues failed work with previous failure analysis, and refuses to start a second worker while an invoke lock is active.

## Status Snapshot

The harness status command reads existing reports and writes a current snapshot without blocking execution:

```powershell
pwsh -NoProfile -File harness/scripts/get_harness_status.ps1
```

It updates `harness/reports/status.json` and `harness/reports/status.md`, then prints the current phase, whether user action is required, the next action, and the next command. It is a static snapshot command; no watch/daemon process is required.
For the latest failure, the snapshot includes a `failure` object with type, retryability, user-action requirement, and recommended next action. Secret/env gaps, unresolved requirements, and local environment/toolchain failures are treated as user-action items; worker and code-level failures remain retry-oriented.
When the latest seed handoff failure is retryable, the status snapshot points to `run_seed_handoff.ps1 -Resume` instead of a blind fresh dispatch.

## Telegram Notifications

Telegram notification delivery is optional. Set these values outside Git before running harness commands:

```powershell
$env:HARNESS_NOTIFY_PROVIDER="telegram"
$env:HARNESS_NOTIFY_LEVEL="attention"
$env:HARNESS_TELEGRAM_BOT_TOKEN="<bot-token>"
$env:HARNESS_TELEGRAM_CHAT_ID="<chat-id>"
```

After those variables are set, `get_harness_status.ps1` calls `send_harness_notification.ps1` quietly after each snapshot and sends only attention-level statuses by default. Use `harness/configs/notification.template.json` as the safe reference; never commit real Telegram tokens.
# 2026-10-15 배치 및 업그레이드 안내

핵심 엔진은 독립 루트와 `<target>/harness`를 구분합니다. [지원 범위·명령 변환·hook 재설치](layout_support.md)를 확인하세요. 기존 worker를 종료·확인한 뒤 스크립트와 hook/bootstrap을 함께 갱신해야 합니다.
새 실행은 `state/usage/` ledger를 유지하며 선택적 프로필 정책으로 제한합니다. [사용량 및 다음 실행 제한](execution_usage.md)을 참고하세요. 기존 실행은 소급 집계하지 않습니다.

