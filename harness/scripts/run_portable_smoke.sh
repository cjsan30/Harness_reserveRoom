#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-portable-smoke.XXXXXX")"
target_root="$tmp_root/target"
target_harness="$target_root/harness"
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

require_command() {
    name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        printf '%s\n' "required command not found: $name" >&2
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

printf 'portable_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName portable-smoke -Language c11 -Framework none -Force -RunPreflight
sh "$target_harness/scripts/setup_portable_runtime.sh"

for hook_name in pre-commit pre-push pre-merge-commit pre-rebase; do
    hook_path="$target_root/.githooks/$hook_name"
    if [ ! -f "$hook_path" ]; then
        printf '%s\n' "missing installed hook: $hook_path" >&2
        exit 1
    fi
    if [ ! -x "$hook_path" ]; then
        printf '%s\n' "installed hook is not executable: $hook_path" >&2
        exit 1
    fi
done

printf '%s\n' 'portable_smoke: pass'
