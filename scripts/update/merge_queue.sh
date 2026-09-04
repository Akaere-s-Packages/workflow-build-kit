#!/usr/bin/env bash
set -uo pipefail

# Drains the autoPR merge queue one PR at a time.
#
# scripts/update/check_updates.sh (run daily by version-check.yml)
# opens/updates version-bump PRs on branches named `bump/<name>[+<name>...]`,
# but never merges anything itself. This script is the thing that actually
# merges them, per two rules asked for explicitly:
#
#   1. A bump/* PR only merges once its own pr-preview build — the CI that
#      triggers automatically the moment the PR opens — has actually passed.
#   2. Merges never overlap: this repo's Actions must be completely idle
#      (nothing queued or in progress, anywhere in the repo) before the next
#      one happens, so a merge's build-and-publish run always finishes
#      before the next bump/* PR gets merged. That makes merging strictly
#      one at a time, in a queue, rather than "however many happen to go
#      green around the same moment".
#
# Run by merge-queue.yml, itself triggered after every pr-preview or
# build-and-publish run completes (either one could be what makes a PR newly
# mergeable, or what frees up the queue) plus workflow_dispatch for manual
# recovery. Each invocation merges AT MOST one PR — the oldest ready one —
# and stops; that merge alone triggers a new build-and-publish run, which
# re-fires merge-queue.yml on completion to consider the next candidate.
# Nothing here needs to loop or poll: the event-driven retrigger *is* the
# loop. merge-queue.yml's own concurrency group additionally guarantees only
# one invocation of this script is ever running at a time, so there's no
# race between two runs both deciding the repo looks idle.
#
# Not distro-specific at all — this is pure GitHub PR-queue mechanics, no
# package-manager tooling involved, so it lives in scripts/update/ (not a
# backends/<distro>/ directory) and needs no changes to support a second
# distro.
#
# Must run inside a checkout of the Registry repo with GH_TOKEN in the
# environment (gh CLI reads it itself; never passed as a literal argument).
#
# Usage: merge_queue.sh

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$lib_dir/run.sh"

READY_CONCLUSIONS="SUCCESS NEUTRAL SKIPPED"

# True if any workflow run other than this queue-drain itself is currently
# queued or in progress anywhere in the repo. merge-queue runs are excluded
# from their own check (this invocation, and any other, are the controller
# — not something a merge needs to wait behind); a `gh run list` failure is
# treated as busy rather than as "go ahead", since a wrongly-skipped busy
# check is exactly the overlapping-merge bug this whole script exists to
# prevent.
repo_is_busy() {
  local status stdout_json entry_id entry_name
  for status in in_progress queued; do
    if ! run gh run list --status "$status" --json databaseId,name --limit 100; then
      echo "::warning::couldn't list $status runs, assuming busy" >&2
      return 0
    fi
    stdout_json="${run_stdout:-}"
    [[ -z "$stdout_json" ]] && stdout_json="[]"
    while IFS=$'\t' read -r entry_id entry_name; do
      [[ -z "$entry_id" ]] && continue
      [[ "$entry_name" == "merge-queue" || "$entry_id" == "${GITHUB_RUN_ID:-}" ]] && continue
      echo "repo busy: $status run '$entry_name' (#$entry_id)"
      return 0
    done < <(jq -r '.[] | "\(.databaseId)\t\(.name)"' <<<"$stdout_json")
  done
  return 1
}

# The oldest open bump/* PR whose own checks have all passed and has no
# merge conflict. Sets $ready_pr_number (empty string if none qualify yet)
# rather than echoing it — this function's own debug output (via run(), and
# the "skipping" messages below) must reach the real log, not get captured
# into a command substitution. Only bump/* branches are ever considered —
# that prefix is exclusively used by check_updates.sh's autoPRs — so a
# human's own PR is never touched by this queue. A PR that isn't ready yet
# is skipped (not an error): trying the next-oldest candidate instead of
# blocking the whole queue behind one slow build keeps a big bundled PR
# from starving smaller, already-ready ones.
find_ready_pr() {
  ready_pr_number=""

  if ! run gh pr list --state open --json number,headRefName,createdAt --limit 100; then
    echo "::warning::couldn't list open PRs" >&2
    return
  fi
  local prs_stdout="${run_stdout:-}"
  [[ -z "$prs_stdout" ]] && prs_stdout="[]"
  local prs_json
  prs_json="$(jq -c '[.[] | select(.headRefName | startswith("bump/"))] | sort_by(.createdAt)' <<<"$prs_stdout")"

  local number
  while IFS= read -r number; do
    [[ -z "$number" ]] && continue

    if ! run gh pr view "$number" --json mergeable,statusCheckRollup; then
      continue
    fi
    local view_json="$run_stdout"

    local mergeable
    mergeable="$(jq -r '.mergeable' <<<"$view_json")"
    if [[ "$mergeable" != "MERGEABLE" ]]; then
      echo "PR #$number isn't cleanly mergeable yet ($mergeable), skipping for now"
      continue
    fi

    local rollup_len
    rollup_len="$(jq '(.statusCheckRollup // []) | length' <<<"$view_json")"
    if [[ "$rollup_len" -eq 0 ]]; then
      echo "PR #$number has no status checks reported yet, skipping for now"
      continue
    fi

    local not_ready
    not_ready="$(jq -r --arg ready "$READY_CONCLUSIONS" '
      (.statusCheckRollup // [])
      | map(.conclusion // .state)
      | unique
      | map(select(. as $s | ($ready | split(" ") | index($s)) | not))
      | join(",")
    ' <<<"$view_json")"
    if [[ -n "$not_ready" ]]; then
      echo "PR #$number checks not all green yet (not ready: $not_ready), skipping for now"
      continue
    fi

    ready_pr_number="$number"
    return
  done < <(jq -r '.[].number' <<<"$prs_json")
}

main() {
  if repo_is_busy; then
    echo "another Actions run is in progress/queued — leaving the queue alone this time"
    return 0
  fi

  find_ready_pr
  if [[ -z "$ready_pr_number" ]]; then
    echo "no bump/* PR is ready to merge right now"
    return 0
  fi

  if ! run gh pr merge "$ready_pr_number" --rebase --delete-branch; then
    echo "::warning::failed to merge PR #$ready_pr_number" >&2
    return 0
  fi
  echo "merged PR #$ready_pr_number, branch deleted"
  return 0
}

main
exit $?
