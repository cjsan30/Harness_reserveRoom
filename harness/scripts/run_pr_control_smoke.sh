#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
harness_dir="$(CDPATH= cd "$script_dir/.." && pwd)"
. "$script_dir/powershell_env.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-pr-control-smoke.XXXXXX")"
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
mkdir -p "$state_dir"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    printf '%s\n' "github.com"
    exit 0
fi

if [ "$1" != "pr" ]; then
    printf '%s\n' "unsupported fake gh command: $*" >&2
    exit 1
fi

cmd="$2"
shift 2

case "$cmd" in
    view)
        selector="$1"
        if [ ! -f "$state_dir/pr.json" ]; then
            printf '%s\n' "no pull request found for $selector" >&2
            exit 1
        fi
        cat "$state_dir/pr.json"
        ;;
    create)
        base=""
        head=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --base) base="$2"; shift 2 ;;
                --head) head="$2"; shift 2 ;;
                --title) shift 2 ;;
                --body-file) shift 2 ;;
                --draft) shift ;;
                *) shift ;;
            esac
        done
        head_oid="$(git rev-parse "$head")"
        cat > "$state_dir/pr.json" <<JSON
{"number":1,"url":"https://github.example.invalid/owner/repo/pull/1","state":"OPEN","isDraft":false,"headRefName":"$head","headRefOid":"$head_oid","baseRefName":"$base","baseRefOid":"base","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","title":"Harness candidate"}
JSON
        printf '%s\n' "https://github.example.invalid/owner/repo/pull/1"
        ;;
    checks)
        cat <<'JSON'
[{"name":"Harness CI","state":"SUCCESS","bucket":"pass","workflow":"Harness CI","link":"https://github.example.invalid/checks/1","startedAt":"","completedAt":""}]
JSON
        ;;
    merge)
        printf '%s\n' "merged"
        ;;
    *)
        printf '%s\n' "unsupported fake gh pr command: $cmd" >&2
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

printf 'pr_control_smoke_root: %s\n' "$target_root"
printf 'powershell: %s\n' "$ps_cmd"
printf 'fake_gh: %s\n' "$fake_bin/gh"

run_ps_file "$target_harness/scripts/init_project_adapter.ps1" -ProjectName pr-control-smoke -Language c11 -Framework none -Force -RunPreflight >/dev/null
git -C "$target_root" add -A
git -C "$target_root" -c user.name='Harness PR' -c user.email='harness-pr@example.invalid' commit --no-verify -m 'bootstrap target' >/dev/null

git -C "$target_root" checkout -B test/pr-candidate >/dev/null 2>&1
printf '%s\n' "candidate" > "$target_root/pr_candidate.txt"
git -C "$target_root" add -A
git -C "$target_root" -c user.name='Harness PR' -c user.email='harness-pr@example.invalid' commit --no-verify -m 'candidate change' >/dev/null

run_ps_file "$target_harness/scripts/run_git_gate.ps1" -Stage final -Command true -AllowWeakCommand -RepositoryRoot "$target_root" >/dev/null
approval_output="$(run_ps_file "$target_harness/scripts/request_main_merge_approval.ps1" -SourceBranch test/pr-candidate -RepositoryRoot "$target_root")"
approval_id="$(printf '%s\n' "$approval_output" | awk -F': ' '/^approval_id:/ { print $2; exit }')"
run_ps_file "$target_harness/scripts/set_main_merge_approval.ps1" -ApprovalId "$approval_id" -Status approved -Approver smoke -RepositoryRoot "$target_root" >/dev/null

run_ps_file "$target_harness/scripts/open_pr_candidate.ps1" -SourceBranch test/pr-candidate -SkipPush -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/check_pr_status.ps1" -PullRequest test/pr-candidate -RepositoryRoot "$target_root" >/dev/null
run_ps_file "$target_harness/scripts/merge_pr_if_allowed.ps1" -PullRequest test/pr-candidate -ApprovalId "$approval_id" -RepositoryRoot "$target_root" >/dev/null

printf '%s\n' 'pr_control_smoke: pass'
