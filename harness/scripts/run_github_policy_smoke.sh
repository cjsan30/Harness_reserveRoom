#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-github-policy-smoke.XXXXXX")"
target_root="$tmp_root/target"
target_harness="$target_root/harness"
fake_bin="$tmp_root/fake-bin"
fake_state="$tmp_root/fake-gh-state"

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
    mkdir -p "$fake_bin" "$fake_state"
    cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env sh
set -eu

state_dir="${FAKE_GH_STATE:?FAKE_GH_STATE is required}"
ruleset_file="$state_dir/ruleset.json"
mkdir -p "$state_dir"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    printf '%s\n' "github.com"
    exit 0
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    cat <<'JSON'
{"nameWithOwner":"owner/repo","url":"https://github.example.invalid/owner/repo","defaultBranchRef":{"name":"main"}}
JSON
    exit 0
fi

if [ "$1" != "api" ]; then
    printf '%s\n' "unsupported fake gh command: $*" >&2
    exit 1
fi

endpoint="$2"
shift 2
method="GET"
input_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --method) method="$2"; shift 2 ;;
        --input) input_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "$endpoint:$method" in
    repos/{owner}/{repo}/rulesets:GET)
        if [ -f "$ruleset_file" ]; then
            printf '%s\n' '[{"id":1,"name":"Harness Main Protection","target":"branch","enforcement":"active"}]'
        else
            printf '%s\n' '[]'
        fi
        ;;
    repos/{owner}/{repo}/rulesets/1:GET)
        if [ -f "$ruleset_file" ]; then
            cat "$ruleset_file"
        else
            printf '%s\n' "ruleset missing" >&2
            exit 1
        fi
        ;;
    repos/{owner}/{repo}/rulesets:POST|repos/{owner}/{repo}/rulesets/1:PUT)
        if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
            printf '%s\n' "missing ruleset input file" >&2
            exit 1
        fi
        cp "$input_file" "$ruleset_file"
        cat "$ruleset_file"
        ;;
    *)
        printf '%s\n' "unsupported fake gh api command: $endpoint $method" >&2
        exit 1
        ;;
esac
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
FAKE_GH_STATE="$fake_state"
export PATH FAKE_GH_STATE

printf 'github_policy_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"
printf 'fake_gh: %s\n' "$fake_bin/gh"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName github-policy-smoke -Language c11 -Framework none -Force -RunPreflight >/dev/null
run_ps_file "$target_harness/scripts/install_github_actions_workflow.ps1" -RepositoryRoot "$target_root" >/dev/null

if run_ps_file "$target_harness/scripts/audit_github_policy.ps1" -RepositoryRoot "$target_root" >/dev/null 2>&1; then
    printf '%s\n' "github policy audit unexpectedly passed before ruleset install" >&2
    exit 1
fi

run_ps_file "$target_harness/scripts/install_github_ruleset.ps1" -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/audit_github_policy.ps1" -RepositoryRoot "$target_root" >/dev/null

printf '%s\n' 'github_policy_smoke: pass'
