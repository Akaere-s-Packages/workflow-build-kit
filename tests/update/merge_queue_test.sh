#!/usr/bin/env bash
set -euo pipefail

# Exercises merge_queue.sh's decision logic against a fake `gh` — no real
# GitHub API access needed. The fake gh reads canned JSON from
# $GH_FIXTURES/{runs_<status>.json,prs.json,pr_view_<number>.json} and logs
# every invocation to $GH_LOG, plus every `gh pr merge <n> ...` call's PR
# number to $GH_MERGE_LOG.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

make_fake_gh() {
  local bin_dir="$1"
  cat > "$bin_dir/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "${GH_LOG:?}"

case "$1 $2" in
  "run list")
    status="$4"
    cat "${GH_FIXTURES:?}/runs_${status}.json" 2>/dev/null || echo "[]"
    ;;
  "pr list")
    cat "$GH_FIXTURES/prs.json" 2>/dev/null || echo "[]"
    ;;
  "pr view")
    number="$3"
    cat "$GH_FIXTURES/pr_view_${number}.json" 2>/dev/null || echo "{}"
    ;;
  "pr merge")
    number="$3"
    echo "$number" >> "${GH_MERGE_LOG:?}"
    exit "${GH_MERGE_EXIT:-0}"
    ;;
  *)
    echo "unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
GH
  chmod +x "$bin_dir/gh"
}

setup() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/fixtures"
  make_fake_gh "$tmp/bin"
  echo "[]" > "$tmp/fixtures/runs_in_progress.json"
  echo "[]" > "$tmp/fixtures/runs_queued.json"
  echo "[]" > "$tmp/fixtures/prs.json"
  echo "$tmp"
}

run_merge_queue() {
  local tmp="$1"
  (
    export PATH="$tmp/bin:$PATH"
    export GH_FIXTURES="$tmp/fixtures"
    export GH_LOG="$tmp/gh.log"
    export GH_MERGE_LOG="$tmp/merge.log"
    export GH_TOKEN=fake
    : > "$GH_LOG"
    "$repo_root/scripts/update/merge_queue.sh"
  )
}

test_busy_repo_skips_merge() {
  local tmp; tmp="$(setup)"
  echo '[{"databaseId":111,"name":"build-and-publish"}]' > "$tmp/fixtures/runs_in_progress.json"

  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"leaving the queue alone"* ]] || fail "expected busy message, got: $output"
  [[ ! -s "$tmp/merge.log" ]] || fail "should not have attempted any merge while busy"

  rm -rf "$tmp"
  echo "PASS: test_busy_repo_skips_merge"
}

test_own_run_excluded_from_busy_check() {
  local tmp; tmp="$(setup)"
  echo '[{"databaseId":42,"name":"merge-queue"},{"databaseId":99,"name":"merge-queue"}]' > "$tmp/fixtures/runs_in_progress.json"
  echo '[{"number":7,"headRefName":"bump/asusctl","createdAt":"2026-09-01T00:00:00Z"}]' > "$tmp/fixtures/prs.json"
  cat > "$tmp/fixtures/pr_view_7.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}
JSON

  local output
  output="$(GITHUB_RUN_ID=42 run_merge_queue "$tmp")"
  [[ "$output" == *"merged PR #7"* ]] || fail "own merge-queue run(s) should not count as busy; output: $output"
  assert_eq "7" "$(cat "$tmp/merge.log")"

  rm -rf "$tmp"
  echo "PASS: test_own_run_excluded_from_busy_check"
}

test_no_ready_pr() {
  local tmp; tmp="$(setup)"
  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"no bump/* PR is ready"* ]] || fail "expected no-ready-PR message, got: $output"
  [[ ! -s "$tmp/merge.log" ]] || fail "should not have attempted any merge"

  rm -rf "$tmp"
  echo "PASS: test_no_ready_pr"
}

test_merges_ready_pr() {
  local tmp; tmp="$(setup)"
  echo '[{"number":12,"headRefName":"bump/claude-code","createdAt":"2026-09-01T00:00:00Z"}]' > "$tmp/fixtures/prs.json"
  cat > "$tmp/fixtures/pr_view_12.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"NEUTRAL"}]}
JSON

  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"merged PR #12, branch deleted"* ]] || fail "expected merge message, got: $output"
  assert_eq "12" "$(cat "$tmp/merge.log")"
  grep -q -- '--delete-branch' "$tmp/gh.log" || fail "merge must pass --delete-branch"
  grep -q -- '--rebase' "$tmp/gh.log" || fail "merge must pass --rebase"

  rm -rf "$tmp"
  echo "PASS: test_merges_ready_pr"
}

test_skips_not_ready_tries_next_oldest() {
  local tmp; tmp="$(setup)"
  # pr 5 is older but still has a failing check; pr 6 is newer but ready —
  # the queue must skip 5 (not block behind it) and merge 6.
  cat > "$tmp/fixtures/prs.json" <<'JSON'
[
  {"number":5,"headRefName":"bump/pkg-a","createdAt":"2026-09-01T00:00:00Z"},
  {"number":6,"headRefName":"bump/pkg-b","createdAt":"2026-09-02T00:00:00Z"}
]
JSON
  cat > "$tmp/fixtures/pr_view_5.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE"}]}
JSON
  cat > "$tmp/fixtures/pr_view_6.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}
JSON

  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"PR #5 checks not all green yet"* ]] || fail "expected PR #5 to be reported not-ready: $output"
  [[ "$output" == *"merged PR #6, branch deleted"* ]] || fail "expected PR #6 to be merged: $output"
  assert_eq "6" "$(cat "$tmp/merge.log")"

  rm -rf "$tmp"
  echo "PASS: test_skips_not_ready_tries_next_oldest"
}

test_non_bump_pr_ignored() {
  local tmp; tmp="$(setup)"
  echo '[{"number":9,"headRefName":"fix/typo","createdAt":"2026-09-01T00:00:00Z"}]' > "$tmp/fixtures/prs.json"

  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"no bump/* PR is ready"* ]] || fail "a non-bump/* PR must never be considered: $output"
  [[ ! -s "$tmp/merge.log" ]] || fail "should not have attempted any merge"

  rm -rf "$tmp"
  echo "PASS: test_non_bump_pr_ignored"
}

test_busy_repo_skips_merge
test_own_run_excluded_from_busy_check
test_no_ready_pr
test_merges_ready_pr
test_skips_not_ready_tries_next_oldest
test_non_bump_pr_ignored
echo "merge_queue tests passed"
