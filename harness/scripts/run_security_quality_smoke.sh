#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-security-quality-smoke.XXXXXX")"
target_root="$tmp_root/target"
target_harness="$target_root/harness"
fake_bin="$tmp_root/fake-bin"

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

write_fake_gh() {
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env sh
set -eu

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    printf '%s\n' "github.com"
    exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "repos/{owner}/{repo}" ]; then
    cat <<'JSON'
{
  "full_name": "owner/repo",
  "security_and_analysis": {
    "dependabot_security_updates": { "status": "enabled" },
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
JSON
    exit 0
fi

printf '%s\n' "unsupported fake gh command: $*" >&2
exit 1
FAKE_GH
    chmod +x "$fake_bin/gh"
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
write_fake_gh

PATH="$fake_bin:$PATH"
export PATH

printf 'security_quality_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"
printf 'fake_gh: %s\n' "$fake_bin/gh"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName security-quality-smoke -Language typescript -Framework next -Force -RunPreflight >/dev/null
run_ps_file "$target_harness/scripts/install_security_baseline.ps1" -Force -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/audit_security_baseline.ps1" -CheckGitHubSecuritySettings -RequireGitHubSecuritySettings -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/install_precommit_baseline.ps1" -Force -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/audit_precommit_baseline.ps1" -RepositoryRoot "$target_root" >/dev/null

printf '%s\n' 'security_quality_smoke: pass'
