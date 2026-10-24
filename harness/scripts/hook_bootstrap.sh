#!/bin/sh
# Sourced by installed hooks. Resolve policy from the main checkout even when
# Git invokes a shared hook from an isolated worktree without worker env vars.
workspace_root="$(git rev-parse --show-toplevel)"
common_dir="$(git rev-parse --git-common-dir)"
case "$common_dir" in /*|[A-Za-z]:*) ;; *) common_dir="$workspace_root/$common_dir" ;; esac
main_root="$(cd "$common_dir/.." && pwd)"
harness_root="${CODEX_HARNESS_ROOT:-$main_root}"
if command -v cygpath >/dev/null 2>&1; then harness_root="$(cygpath -u "$harness_root")"; fi
if command -v wslpath >/dev/null 2>&1; then
  case "$harness_root" in [A-Za-z]:*) harness_root="$(wslpath -u "$harness_root")" ;; esac
fi
engine_root=''
for candidate in "$harness_root" "$harness_root/harness"; do
  if [ -f "$candidate/scripts/harness_common.ps1" ]; then
    if [ -n "$engine_root" ]; then printf '%s\n' 'ambiguous Harness layout' >&2; exit 1; fi
    engine_root="$candidate"
  fi
done
if [ -z "$engine_root" ]; then printf '%s\n' 'Harness engine not found for Git hook' >&2; exit 1; fi
. "$engine_root/scripts/path_common.sh"
ps_cmd="$(sh "$engine_root/scripts/resolve_powershell.sh")"
ps_base="$(basename "$ps_cmd" | tr '[:upper:]' '[:lower:]')"
. "$engine_root/scripts/powershell_env.sh"
prepare_harness_powershell_env "$engine_root" "$ps_base"
script_path="$(to_harness_powershell_path "$engine_root/scripts/assert_git_action_allowed.ps1" "$ps_base")"
workspace_root="$(to_harness_powershell_path "$workspace_root" "$ps_base")"
CODEX_HARNESS_ROOT="$(to_harness_powershell_path "$harness_root" "$ps_base")"
export CODEX_HARNESS_ROOT
