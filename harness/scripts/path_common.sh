#!/usr/bin/env sh

is_harness_windows_path() {
    case "${1:-}" in
        [A-Za-z]:\\*|[A-Za-z]:/*|\\\\*|//*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_harness_posix_path() {
    case "${1:-}" in
        /*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

to_harness_shell_path() {
    input_path="${1:-}"
    if [ -z "$input_path" ]; then
        printf '%s\n' "$input_path"
        return 0
    fi

    if command -v cygpath >/dev/null 2>&1 && is_harness_windows_path "$input_path"; then
        cygpath -u "$input_path" 2>/dev/null || printf '%s\n' "$input_path"
        return 0
    fi

    if command -v wslpath >/dev/null 2>&1 && is_harness_windows_path "$input_path"; then
        wslpath -u "$input_path" 2>/dev/null || printf '%s\n' "$input_path"
        return 0
    fi

    printf '%s\n' "$input_path"
}

to_harness_powershell_path() {
    input_path="${1:-}"
    ps_base="${2:-}"
    if [ -z "$input_path" ]; then
        printf '%s\n' "$input_path"
        return 0
    fi

    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$input_path" 2>/dev/null || printf '%s\n' "$input_path"
        return 0
    fi

    case "$ps_base" in
        powershell.exe|pwsh.exe)
            if command -v wslpath >/dev/null 2>&1 && is_harness_posix_path "$input_path"; then
                wslpath -w "$input_path" 2>/dev/null || printf '%s\n' "$input_path"
                return 0
            fi
            ;;
    esac

    printf '%s\n' "$input_path"
}
