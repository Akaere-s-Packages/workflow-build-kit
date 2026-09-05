#!/usr/bin/env bash
set -euo pipefail

# Exercises merge_queue.sh's decision logic against a fake `gh` — no real
# GitHub API access needed. The fake gh reads canned JSON from
# $GH_FIXTURES/{runs_<status>.json,prs.json,pr_view_<number>.json} and logs
# every invocation to $GH_LOG, plus every `gh pr merge <n> ...` call's PR
# number to $GH_MERGE_LOG.
#
# Two bits of state the fake gh fakes across repeated calls, since
# merge_queue.sh now loops within a single run instead of doing one thing
# and exiting:
#   - `pr list` filters out any PR number already recorded in GH_MERGE_LOG,
#     so a merged PR stops looking "open" on the next iteration (otherwise
#     the drain loop would try to re-merge it forever).
#   - `run list` counts its own invocations (across both --status values)
#     and, if $GH_FIXTURES/runs_<status>_<call number>.json exists, serves
#     that instead of the plain runs_<status>.json — letting a test script
#     "the repo goes busy right after this merge, then idle again" without
#     needing real sleeps.

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
    count_file="${GH_RUN_LIST_COUNT_FILE:?}"
    n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$count_file"
    if [[ -f "${GH_FIXTURES:?}/runs_${status}_${n}.json" ]]; then
      cat "${GH_FIXTURES}/runs_${status}_${n}.json"
    else
      cat "${GH_FIXTURES}/runs_${status}.json" 2>/dev/null || echo "[]"
    fi
    ;;
  "pr list")
    merged_json="$(jq -R -s -c 'split("\n") | map(select(length>0) | tonumber)' "${GH_MERGE_LOG:?}" 2>/dev/null || echo '[]')"
    if [[ -f "${GH_FIXTURES:?}/prs.json" ]]; then
      jq --argjson merged "$merged_json" '[.[] | select((.number as $n | ($merged | index($n))) == null)]' "$GH_FIXTURES/prs.json"
    else
      echo "[]"
    fi
    ;;
  "pr view")
    number="$3"
    cat "$GH_FIXTURES/pr_view_${number}.json" 2>/dev/null || echo "{}"
    ;;
  "pr merge")
    number="$3"
    exit_code="${GH_MERGE_EXIT:-0}"
    [[ "$exit_code" == "0" ]] && echo "$number" >> "${GH_MERGE_LOG:?}"
    exit "$exit_code"
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
    export GH_RUN_LIST_COUNT_FILE="$tmp/run_list_count"
    export GH_TOKEN=fake
    # Fast by default: no real waiting unless a test overrides these to
    # exercise the busy/retry path specifically.
    export IDLE_POLL_INTERVAL_SECONDS="${IDLE_POLL_INTERVAL_SECONDS:-0}"
    export IDLE_MAX_WAIT_SECONDS="${IDLE_MAX_WAIT_SECONDS:-5}"
    : > "$GH_LOG"
    : > "$GH_MERGE_LOG"
    # Merge stderr into the captured output — several messages tests
    # assert on (::warning:: lines, the merge-failure warning) are written
    # to stderr by merge_queue.sh's run() helper and its own `>&2` echoes.
    "$repo_root/scripts/update/merge_queue.sh" 2>&1
  )
}

test_busy_repo_skips_merge() {
  local tmp; tmp="$(setup)"
  echo '[{"databaseId":111,"name":"build-and-publish"}]' > "$tmp/fixtures/runs_in_progress.json"

  local output
  output="$(IDLE_MAX_WAIT_SECONDS=0 run_merge_queue "$tmp")"
  [[ "$output" == *"giving up on this drain"* ]] || fail "expected give-up message, got: $output"
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
  [[ "$output" == *"no bump/* PR is ready"* ]] || fail "expected the drain to stop after the only PR merged: $output"
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

test_drains_multiple_ready_prs_in_one_run() {
  local tmp; tmp="$(setup)"
  cat > "$tmp/fixtures/prs.json" <<'JSON'
[
  {"number":5,"headRefName":"bump/pkg-a","createdAt":"2026-09-01T00:00:00Z"},
  {"number":6,"headRefName":"bump/pkg-b","createdAt":"2026-09-02T00:00:00Z"}
]
JSON
  cat > "$tmp/fixtures/pr_view_5.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}
JSON
  cat > "$tmp/fixtures/pr_view_6.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}
JSON
  # Both PRs are ready from the start, and the repo is idle throughout
  # except for one busy blip on the 3rd `run list` call (the in_progress
  # check right after PR 5 merges — simulating the build-and-publish run
  # that merge just triggered). The drain must wait that out before
  # touching PR 6, not race ahead of it.
  echo '[{"databaseId":222,"name":"build-and-publish"}]' > "$tmp/fixtures/runs_in_progress_3.json"

  local output
  output="$(run_merge_queue "$tmp")"
  [[ "$output" == *"merged PR #5, branch deleted"* ]] || fail "expected PR #5 merged: $output"
  [[ "$output" == *"repo busy: in_progress run 'build-and-publish'"* ]] || fail "expected a busy wait between merges: $output"
  [[ "$output" == *"merged PR #6, branch deleted"* ]] || fail "expected PR #6 merged after the wait: $output"
  [[ "$output" == *"no bump/* PR is ready"* ]] || fail "expected the drain to stop once both are merged: $output"
  assert_eq "$(printf '5\n6')" "$(cat "$tmp/merge.log")"

  rm -rf "$tmp"
  echo "PASS: test_drains_multiple_ready_prs_in_one_run"
}

test_failed_merge_is_not_retried_forever() {
  local tmp; tmp="$(setup)"
  echo '[{"number":8,"headRefName":"bump/pkg-c","createdAt":"2026-09-01T00:00:00Z"}]' > "$tmp/fixtures/prs.json"
  cat > "$tmp/fixtures/pr_view_8.json" <<'JSON'
{"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]}
JSON

  local output
  output="$(GH_MERGE_EXIT=1 run_merge_queue "$tmp")"
  [[ "$output" == *"failed to merge PR #8"* ]] || fail "expected merge failure warning: $output"
  [[ "$output" == *"already failed to merge earlier this run, skipping"* ]] || fail "expected the drain to give up on PR #8 instead of looping forever: $output"
  [[ ! -s "$tmp/merge.log" ]] || fail "a failed merge should not appear in merge.log"

  rm -rf "$tmp"
  echo "PASS: test_failed_merge_is_not_retried_forever"
}

test_busy_repo_skips_merge
test_own_run_excluded_from_busy_check
test_no_ready_pr
test_merges_ready_pr
test_skips_not_ready_tries_next_oldest
test_non_bump_pr_ignored
test_drains_multiple_ready_prs_in_one_run
test_failed_merge_is_not_retried_forever
echo "merge_queue tests passed"
