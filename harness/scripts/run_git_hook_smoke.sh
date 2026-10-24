#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-git-hook-smoke.XXXXXX")"
target_root="$tmp_root/target"
target_harness="$target_root/harness"
remote_root="$tmp_root/remote.git"

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

require_command() {
    name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        printf '%s\n' "required command not found: $name" >&2
        exit 1
    fi
}

require_blocked() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '%s\n' "expected command to be blocked: $label" >&2
        exit 1
    fi
}

require_command git
require_command rsync

mkdir -p "$target_root"
rsync -a --exclude .git --exclude .agents --exclude .codex "$harness_dir"/ "$target_harness"/

git -C "$target_root" init -q
git -C "$target_root" checkout -B main >/dev/null 2>&1
git init --bare -q "$remote_root"

ps_cmd="$(sh "$target_harness/scripts/resolve_powershell.sh")"
ps_base="$(basename "$ps_cmd" | tr '[:upper:]' '[:lower:]')"
prepare_harness_powershell_env "$target_harness" "$ps_base"

printf 'git_hook_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName git-hook-smoke -Language c11 -Framework none -Force -RunPreflight >/dev/null

git -C "$target_root" add -A
require_blocked "main commit before bootstrap gate" git -C "$target_root" -c user.name="Harness Hook" -c user.email="hook@example.invalid" commit -m "blocked main commit"
require_blocked "weak bootstrap gate command" run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage bootstrap -Command true -RepositoryRoot "$target_root"

run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage bootstrap -Command true -AllowWeakCommand -RepositoryRoot "$target_root" >/dev/null
git -C "$target_root" -c user.name="Harness Hook" -c user.email="hook@example.invalid" commit -m "bootstrap baseline" >/dev/null

git -C "$target_root" checkout -B agent-tests/hook-test >/dev/null 2>&1
printf '%s\n' "feature change" > "$target_root/hook_feature.txt"
git -C "$target_root" add -A
git -C "$target_root" -c user.name="Harness Hook" -c user.email="hook@example.invalid" commit -m "feature work before gate" >/dev/null

git -C "$target_root" remote add origin "$remote_root"
require_blocked "feature push before feature gate" git -C "$target_root" push origin agent-tests/hook-test:agent-tests/hook-test
require_blocked "pipeline failure in feature gate" run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage feature -Owner agent-tests -Command "false | true" -AllowCommittedHead -RepositoryRoot "$target_root"

run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage feature -Owner agent-tests -Command true -AllowWeakCommand -AllowCommittedHead -RepositoryRoot "$target_root" >/dev/null
require_blocked "feature refspec into dev" git -C "$target_root" push origin agent-tests/hook-test:dev
git -C "$target_root" push origin agent-tests/hook-test:agent-tests/hook-test >/dev/null 2>&1

git -C "$target_root" checkout -B dev main >/dev/null 2>&1
require_blocked "direct dev commit" git -C "$target_root" -c user.name="Harness Hook" -c user.email="hook@example.invalid" commit --allow-empty -m "blocked dev commit"
require_blocked "merge before integration promotion" run_ps_file "$target_harness/scripts/merge_authorized_branch.ps1" -SourceBranch agent-tests/hook-test -TargetBranch dev -RepositoryRoot "$target_root"

git -C "$target_root" checkout agent-tests/hook-test >/dev/null 2>&1
run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage integration -Command true -AllowWeakCommand -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/authorize_branch_promotion.ps1" -SourceBranch agent-tests/hook-test -TargetBranch dev -AuthorizedBy hook-smoke -RepositoryRoot "$target_root" >/dev/null
git -C "$target_root" checkout dev >/dev/null 2>&1
run_ps_file "$target_harness/scripts/merge_authorized_branch.ps1" -SourceBranch agent-tests/hook-test -TargetBranch dev -RepositoryRoot "$target_root" >/dev/null
git -C "$target_root" push origin dev:dev >/dev/null 2>&1

git -C "$target_root" checkout -B agent-tests/unmerged dev >/dev/null 2>&1
printf '%s\n' "unmerged change" > "$target_root/hook_unmerged.txt"
git -C "$target_root" add -A
git -C "$target_root" -c user.name="Harness Hook" -c user.email="hook@example.invalid" commit -m "unmerged work" >/dev/null
run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage feature -Owner agent-tests -Command true -AllowWeakCommand -AllowCommittedHead -RepositoryRoot "$target_root" >/dev/null
git -C "$target_root" push origin agent-tests/unmerged:agent-tests/unmerged >/dev/null 2>&1
git -C "$target_root" checkout dev >/dev/null 2>&1

require_blocked "unmerged feature branch deletion" git -C "$target_root" push origin --delete agent-tests/unmerged
require_blocked "protected dev branch deletion" git -C "$target_root" push origin --delete dev
git -C "$target_root" push origin --delete agent-tests/hook-test >/dev/null 2>&1

printf '%s\n' 'git_hook_smoke: pass'
