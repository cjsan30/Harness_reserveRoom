#!/usr/bin/env sh
set -eu
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/path_common.sh"
in_wsl=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || { [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease; }; then in_wsl=1; fi

if [ -n "${CODEX_HARNESS_PWSH:-}" ]; then
    candidate="$(to_harness_shell_path "$CODEX_HARNESS_PWSH")"
    if [ "$in_wsl" -eq 1 ]; then
        case "$candidate" in *.exe|*.EXE) printf '%s\n' 'native pwsh is required inside WSL; Windows runtime refused' >&2; exit 1 ;; esac
    fi
    if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
    printf '%s\n' "CODEX_HARNESS_PWSH is set but not executable: $CODEX_HARNESS_PWSH" >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' pwsh
    exit 0
fi

for candidate in "${HOME:-}/.local/bin/pwsh" "${HOME:-}/.local/powershell/7/pwsh" "${HOME:-}"/.local/powershell/*/pwsh; do
    if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

if [ "$in_wsl" -eq 1 ]; then
    printf '%s\n' "native pwsh is required inside WSL/Linux; powershell.exe fallback is intentionally disabled here" >&2
    exit 1
fi

if command -v powershell >/dev/null 2>&1; then
    printf '%s\n' powershell
    exit 0
fi

if command -v powershell.exe >/dev/null 2>&1; then
    printf '%s\n' powershell.exe
    exit 0
fi

printf '%s\n' "no PowerShell executable found; install PowerShell 7+ (pwsh)" >&2
exit 1
