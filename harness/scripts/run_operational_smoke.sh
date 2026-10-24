#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-operational-smoke.XXXXXX")"
target_root="$tmp_root/target"
target_harness="$target_root/harness"
fake_bin="$tmp_root/fake-bin"
ps_cmd=""
ps_base=""

require_command() {
    name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        printf '%s\n' "required command not found: $name" >&2
        exit 1
    fi
}

run_ps_file() {
    file_path="$1"
    shift
    case "$ps_base" in
        powershell.exe)
            if command -v cygpath >/dev/null 2>&1; then
                file_path="$(cygpath -w "$file_path")"
            elif command -v wslpath >/dev/null 2>&1; then
                file_path="$(wslpath -w "$file_path")"
            fi
            "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$file_path" "$@"
            ;;
        *)
            "$ps_cmd" -NoProfile -File "$file_path" "$@"
            ;;
    esac
}

write_fake_codex() {
    mkdir -p "$fake_bin"
    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env sh
set -eu

if [ "${1:-}" = "--version" ]; then
    printf '%s\n' "codex fake operational-smoke"
    exit 0
fi

out_file=""
work_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            out_file="${2:-}"
            shift 2
            ;;
        -C)
            work_dir="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "$work_dir" ]; then
    cd "$work_dir"
fi

prompt_file="$(mktemp "${TMPDIR:-/tmp}/fake-codex-prompt.XXXXXX")"
cat > "$prompt_file"

if [ -n "$out_file" ]; then
    mkdir -p "$(dirname "$out_file")"
    printf '%s\n' "fake codex result: ${FAKE_CODEX_RESULT:-none}" > "$out_file"
fi

case "${FAKE_CODEX_RESULT:-none}" in
    pass|fail)
        command_line="$(grep "complete_assignment.ps1 -Agent " "$prompt_file" | grep " -Result ${FAKE_CODEX_RESULT}" | head -n 1 || true)"
        agent="$(printf '%s\n' "$command_line" | sed -n 's/.* -Agent \([^ ]*\) -AssignmentId .*/\1/p')"
        assignment_id="$(printf '%s\n' "$command_line" | sed -n 's/.* -AssignmentId \([^ ]*\) -Result .*/\1/p')"
        if [ -z "$agent" ] || [ -z "$assignment_id" ]; then
            printf '%s\n' "fake codex could not parse complete_assignment command" >&2
            exit 2
        fi
        harness_root="${CODEX_HARNESS_ROOT:-$(pwd)}"
        ps="${CODEX_HARNESS_PWSH:-pwsh}"
        "$ps" -NoProfile -File "$harness_root/harness/scripts/complete_assignment.ps1" -Agent "$agent" -AssignmentId "$assignment_id" -Result "$FAKE_CODEX_RESULT"
        ;;
esac

exit "${FAKE_CODEX_EXIT_CODE:-0}"
FAKE_CODEX
    chmod +x "$fake_bin/codex"
}

assert_file_exists() {
    path="$1"
    if [ ! -f "$path" ]; then
        printf '%s\n' "expected file missing: $path" >&2
        exit 1
    fi
}

assert_grep() {
    pattern="$1"
    path="$2"
    if ! grep -q "$pattern" "$path"; then
        printf '%s\n' "expected pattern '$pattern' not found in $path" >&2
        exit 1
    fi
}

require_command git
require_command rsync

mkdir -p "$target_root"
rsync -a --exclude .git --exclude .agents --exclude .codex "$harness_dir"/ "$target_harness"/

git -C "$target_root" init -q
git -C "$target_root" checkout -B main >/dev/null 2>&1

ps_cmd="$(sh "$target_harness/scripts/resolve_powershell.sh")"
ps_base="$(basename "$ps_cmd" | tr '[:upper:]' '[:lower:]')"
prepare_harness_powershell_env "$target_harness" "$ps_base"
write_fake_codex

PATH="$fake_bin:$PATH"
CODEX_HARNESS_PWSH="$ps_cmd"
export PATH CODEX_HARNESS_PWSH

printf 'operational_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"
printf 'fake_codex: %s\n' "$fake_bin/codex"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName operational-smoke -Language c11 -Framework none -Force -RunPreflight

git -C "$target_root" add -A
git -C "$target_root" -c user.name='Harness Smoke' -c user.email='harness-smoke@example.invalid' commit --no-verify -m 'initial operational smoke target' >/dev/null
git -C "$target_root" checkout -B smoke/control >/dev/null 2>&1

cat > "$target_harness/reports/latest_report.md" <<'LATEST_REPORT'
# Latest Harness Report

## Summary

- status: fail
- last_cycle: operational_smoke_001

## Failures

- type: logic
- module: operational-smoke

## Next Actions

- owner: agent-tests
- task: verify retry dispatch without a real target project
LATEST_REPORT

run_ps_file "$target_harness/scripts/run_retry_handoff.ps1" -DryRun
retry_assignment_file="$(find "$target_harness/assignments/agent-tests/inbox" -type f -name '*.md' | sort | head -n 1)"
assert_file_exists "$retry_assignment_file"
retry_assignment_id="$(basename "$retry_assignment_file" .md)"
assert_file_exists "$target_harness/reports/dispatch_packets/$retry_assignment_id.md"

FAKE_CODEX_RESULT=none
export FAKE_CODEX_RESULT
if run_ps_file "$target_harness/scripts/invoke_assignment_codex.ps1" -Agent agent-tests -AssignmentId "$retry_assignment_id"; then
    printf '%s\n' "incomplete fake worker unexpectedly passed" >&2
    exit 1
fi
unset FAKE_CODEX_RESULT
assert_file_exists "$target_harness/assignments/agent-tests/done/${retry_assignment_id}__fail.md"
assert_grep "result: fail" "$target_harness/assignments/agent-tests/done/${retry_assignment_id}__fail.md"
assert_grep "completion_status: worker_did_not_complete_assignment_marked_fail" "$target_harness/reports/agent_runs/${retry_assignment_id}__summary.md"

mkdir -p "$target_harness/reports/seed_plans"
cat > "$target_harness/reports/seed_plans/operational_smoke_seed.md" <<'SEED_PLAN'
# Assignment Seed Plan

## Meta

- plan_id: operational-smoke-seed
- summary: verify seed dispatch without a real target project
- dispatch_mode: serial

## Assignment

- owner: agent-tests
- title: fake pass worker
- work_area: tests
- validation: true

### Task

Use the fake Codex worker to mark this assignment as pass.

### Acceptance

- assignment is completed with result pass

### Notes

none
SEED_PLAN

run_ps_file "$target_harness/scripts/run_seed_handoff.ps1" -DryRun -SkipAutoAdvanceGit -PlanFile "harness/reports/seed_plans/operational_smoke_seed.md"
seed_assignment_file="$target_harness/assignments/agent-tests/inbox/operational-smoke-seed__01__fake-pass-worker.md"
assert_file_exists "$seed_assignment_file"

cat > "$target_harness/reports/seed_plans/operational_smoke_resume.md" <<'RESUME_SEED_PLAN'
# Assignment Seed Plan

## Meta

- plan_id: operational-smoke-resume
- summary: verify seed resume without a real target project
- dispatch_mode: serial

## Assignment

- owner: agent-tests
- title: fake resume worker
- work_area: tests
- validation: true

### Task

Use the fake Codex worker resume path.

### Acceptance

- failed assignment is requeued with previous failure analysis

### Notes

none
RESUME_SEED_PLAN

run_ps_file "$target_harness/scripts/dispatch_seed_plan.ps1" -PlanFile "harness/reports/seed_plans/operational_smoke_resume.md"
resume_assignment_id="operational-smoke-resume__01__fake-resume-worker"
run_ps_file "$target_harness/scripts/claim_assignment.ps1" -Agent agent-tests -AssignmentId "$resume_assignment_id"
run_ps_file "$target_harness/scripts/complete_assignment.ps1" -Agent agent-tests -AssignmentId "$resume_assignment_id" -Result fail
run_ps_file "$target_harness/scripts/get_seed_handoff_resume.ps1" -PlanFile "harness/reports/seed_plans/operational_smoke_resume.md"
assert_grep "status: resumable" "$target_harness/reports/seed_plans/operational-smoke-resume__resume.md"
assert_grep "failed: 1" "$target_harness/reports/seed_plans/operational-smoke-resume__resume.md"

run_ps_file "$target_harness/scripts/run_seed_handoff.ps1" -Resume -DryRun -SkipAutoAdvanceGit -PlanFile "harness/reports/seed_plans/operational_smoke_resume.md"
assert_file_exists "$target_harness/assignments/agent-tests/inbox/${resume_assignment_id}.md"
assert_grep "Previous Failure Analysis" "$target_harness/assignments/agent-tests/inbox/${resume_assignment_id}.md"
assert_grep "Previous Failure Analysis" "$target_harness/reports/dispatch_packets/${resume_assignment_id}.md"

FAKE_CODEX_RESULT=pass
export FAKE_CODEX_RESULT
run_ps_file "$target_harness/scripts/run_seed_handoff.ps1" -SkipAutoAdvanceGit -MaxWorkerAttempts 1 -PlanFile "harness/reports/seed_plans/operational_smoke_seed.md"
unset FAKE_CODEX_RESULT

assert_file_exists "$target_harness/assignments/agent-tests/done/operational-smoke-seed__01__fake-pass-worker__pass.md"
assert_grep "result: pass" "$target_harness/assignments/agent-tests/done/operational-smoke-seed__01__fake-pass-worker__pass.md"
assert_grep "status: pass" "$target_harness/reports/seed_plans/operational-smoke-seed__dispatch_summary.md"
assert_grep "action: claim" "$target_harness/reports/assignment_log.md"
assert_grep "action: complete" "$target_harness/reports/assignment_log.md"

printf '%s\n' 'operational_smoke: pass'
