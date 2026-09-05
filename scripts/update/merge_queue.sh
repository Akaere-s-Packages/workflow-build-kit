#!/usr/bin/env bash
set -uo pipefail

# Drains the autoPR merge queue: keeps merging ready bump/* PRs, one at a
# time, until none are left.
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
# recovery. A single invocation now drains the *whole* queue rather than
# just the next candidate: merge a ready PR, then poll (not just check once)
# until the repo goes idle again — which is what waits out the
# build-and-publish run that merge itself triggers — then look for the next
# ready PR, and keep going until none are left. The event-driven retrigger
# on pr-preview/build-and-publish completion still matters as what kicks a
# drain off (or, if one is already running, queues a rescan behind it via
# merge-queue.yml's own concurrency group) — it's just no longer relied on
# to advance the queue one PR at a time, so a whole backlog clears out in
# one job run instead of one retrigger per PR.
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
#
# IDLE_POLL_INTERVAL_SECONDS / IDLE_MAX_WAIT_SECONDS (both overridable via
# env, mainly for tests) control the idle-wait below.

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$lib_dir/run.sh"

READY_CONCLUSIONS="SUCCESS NEUTRAL SKIPPED"

# How often to re-check while waiting for the repo to go idle, and how long
# to keep waiting before giving up on this drain (a later retrigger, or the
# next scheduled/manual run, picks back up from there). An hour is generous
# for a single build-and-publish run to finish; giving up rather than
# blocking the job forever keeps a stuck/hung run from pinning this job
# open indefinitely.
IDLE_POLL_INTERVAL_SECONDS="${IDLE_POLL_INTERVAL_SECONDS:-30}"
IDLE_MAX_WAIT_SECONDS="${IDLE_MAX_WAIT_SECONDS:-3600}"

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

# Blocks (polling, not a single check) until repo_is_busy reports idle, up
# to IDLE_MAX_WAIT_SECONDS. Returns 1 if that timeout is hit first, so the
# caller can stop this drain rather than holding the job open forever —
# a future retrigger (or the next event) will start a fresh drain.
wait_for_idle() {
  local waited=0
  while repo_is_busy; do
    if (( waited >= IDLE_MAX_WAIT_SECONDS )); then
      echo "::warning::repo still busy after ${waited}s (limit ${IDLE_MAX_WAIT_SECONDS}s) — giving up on this drain, a later trigger will pick back up" >&2
      return 1
    fi
    echo "repo busy — waiting ${IDLE_POLL_INTERVAL_SECONDS}s before checking again"
    sleep "$IDLE_POLL_INTERVAL_SECONDS"
    waited=$(( waited + IDLE_POLL_INTERVAL_SECONDS ))
  done
  return 0
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
#
# $1 (optional): comma-separated PR numbers to skip regardless of their
# state — used within a single drain to exclude a PR whose merge attempt
# already failed this run, so main()'s loop doesn't retry (and get stuck
# on) the same failing PR forever.
find_ready_pr() {
  local skip_csv="${1:-}"
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

    if [[ ",${skip_csv}," == *",${number},"* ]]; then
      echo "PR #$number already failed to merge earlier this run, skipping"
      continue
    fi

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
  local failed_csv=""

  while true; do
    if ! wait_for_idle; then
      return 0
    fi

    find_ready_pr "$failed_csv"
    if [[ -z "$ready_pr_number" ]]; then
      echo "no bump/* PR is ready to merge right now"
      return 0
    fi

    if ! run gh pr merge "$ready_pr_number" --rebase --delete-branch; then
      echo "::warning::failed to merge PR #$ready_pr_number" >&2
      failed_csv="${failed_csv:+$failed_csv,}$ready_pr_number"
      continue
    fi
    echo "merged PR #$ready_pr_number, branch deleted"

    # Give GitHub a moment to register the build-and-publish run this merge
    # just triggered, so the next wait_for_idle sees it as busy instead of
    # racing ahead on stale "idle" state and merging the next PR too soon.
    sleep "$IDLE_POLL_INTERVAL_SECONDS"
  done
}

main
exit $?
