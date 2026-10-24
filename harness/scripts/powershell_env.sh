#!/usr/bin/env sh

prepare_harness_powershell_env() {
    harness_dir="$1"
    ps_base="${2:-}"

    case "$(uname -s 2>/dev/null || printf '%s\n' unknown)" in
        CYGWIN*|MINGW*|MSYS*)
            return 0
            ;;
    esac

    case "$ps_base" in
        powershell.exe|powershell|pwsh.exe)
            return 0
            ;;
    esac

    if [ -z "$harness_dir" ]; then
        return 0
    fi

    harness_key="$(printf '%s' "$harness_dir" | sed 's#[^A-Za-z0-9_.-]#_#g')"
    xdg_root="${CODEX_HARNESS_XDG_ROOT:-${TMPDIR:-/tmp}/codex-harness-xdg/$harness_key}"

    if [ -z "${XDG_CACHE_HOME:-}" ]; then
        XDG_CACHE_HOME="$xdg_root/cache"
        export XDG_CACHE_HOME
    fi
    if [ -z "${XDG_DATA_HOME:-}" ]; then
        XDG_DATA_HOME="$xdg_root/data"
        export XDG_DATA_HOME
    fi
    if [ -z "${XDG_CONFIG_HOME:-}" ]; then
        XDG_CONFIG_HOME="$xdg_root/config"
        export XDG_CONFIG_HOME
    fi

    mkdir -p "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" 2>/dev/null || true
}
