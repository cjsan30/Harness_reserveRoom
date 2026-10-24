#!/usr/bin/env sh
# Fixed entry registry, no eval and no command text assembled from user arguments.
set -eu
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
action="${1:-}"
case "$action" in build|unit|integration|benchmark_smoke|cycle|retry) shift ;; *) printf '%s\n' 'unsupported Harness shell action' >&2; exit 2 ;; esac
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
    printf '%s\n' 'Harness shell: steps accept --preview; cycle accepts --skip-retry-prompt; retry accepts no options.'
    exit 0
fi
case "$action:$#:${1:-}" in
    *:0:) set -- ;;
    build:1:--preview|unit:1:--preview|integration:1:--preview|benchmark_smoke:1:--preview|build:1:-Preview|unit:1:-Preview|integration:1:-Preview|benchmark_smoke:1:-Preview) set -- -Preview ;;
    cycle:1:--skip-retry-prompt|cycle:1:-SkipRetryPrompt) set -- -SkipRetryPrompt ;;
    *) printf '%s\n' 'invalid Harness shell options; use --help (project tool arguments belong in profile commands)' >&2; exit 2 ;;
esac
. "$script_dir/path_common.sh"
ps_cmd="$(sh "$script_dir/resolve_powershell.sh")"
ps_base="$(basename "$ps_cmd" | tr '[:upper:]' '[:lower:]')"
. "$script_dir/powershell_env.sh"
prepare_harness_powershell_env "$(dirname "$script_dir")" "$ps_base"
script_path="$(to_harness_powershell_path "$script_dir/run_harness_shell.ps1" "$ps_base")"
# Only script_path needs conversion; let neither MSYS nor a second shell rewrite argv.
MSYS2_ARG_CONV_EXCL='*'
export MSYS2_ARG_CONV_EXCL
case "$ps_base" in
    powershell|powershell.exe) exec "$ps_cmd" -NoProfile -ExecutionPolicy Bypass -File "$script_path" -Action "$action" "$@" ;;
    *) exec "$ps_cmd" -NoProfile -File "$script_path" -Action "$action" "$@" ;;
esac
