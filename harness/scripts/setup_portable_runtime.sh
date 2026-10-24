#!/usr/bin/env sh
set -eu

skip_preflight=0
if [ "${1:-}" = "--skip-preflight" ]; then
    skip_preflight=1
fi

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
if [ -n "${CODEX_HARNESS_ROOT:-}" ]; then
    repo_root="$CODEX_HARNESS_ROOT"
elif [ -e "$harness_dir/.git" ] || [ "$(basename "$harness_dir")" != harness ]; then
    repo_root="$harness_dir"
else
    repo_root="$(CDPATH= cd "$harness_dir/.." && pwd)"
fi
. "$script_dir/powershell_env.sh"
ps_cmd=""
ps_base=""

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

if command -v chmod >/dev/null 2>&1; then
    chmod +x "$script_dir"/*.sh 2>/dev/null || true
    chmod +x "$harness_dir"/githooks/pre-commit "$harness_dir"/githooks/pre-push "$harness_dir"/githooks/pre-merge-commit "$harness_dir"/githooks/pre-rebase 2>/dev/null || true
fi

printf 'harness_root: %s\n' "$harness_dir"
printf 'repository_root: %s\n' "$repo_root"

if ! command -v git >/dev/null 2>&1; then
    printf '%s\n' 'git is required but was not found in PATH' >&2
    exit 1
fi

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' 'repository root is not a Git worktree; skipping hook installation and preflight'
    exit 0
fi

ps_cmd="$(sh "$script_dir/resolve_powershell.sh")"
ps_base="$(basename "$ps_cmd" | tr '[:upper:]' '[:lower:]')"
prepare_harness_powershell_env "$harness_dir" "$ps_base"
printf 'powershell: %s\n' "$ps_cmd"

run_ps_file "$script_dir/install_git_hooks.ps1"

if [ "$skip_preflight" -eq 0 ]; then
    run_ps_file "$script_dir/run_harness_preflight.ps1"
fi

printf '%s\n' 'portable runtime setup complete'
