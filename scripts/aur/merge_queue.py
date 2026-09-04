#!/usr/bin/env python3
"""Drains the autoPR merge queue one PR at a time.

check_updates.py (run daily by version-check.yml) opens/updates version-bump
PRs on branches named `bump/<name>[+<name>...]`, but never merges anything
itself. This script is the thing that actually merges them, per two rules
asked for explicitly:

  1. A bump/* PR only merges once its own pr-preview build — the CI that
     triggers automatically the moment the PR opens — has actually passed.
  2. Merges never overlap: this repo's Actions must be completely idle
     (nothing queued or in progress, anywhere in the repo) before the next
     one happens, so a merge's build-and-publish run always finishes
     before the next bump/* PR gets merged. That makes merging strictly
     one at a time, in a queue, rather than "however many happen to go
     green around the same moment".

Run by merge-queue.yml, itself triggered after every pr-preview or
build-and-publish run completes (either one could be what makes a PR newly
mergeable, or what frees up the queue) plus workflow_dispatch for manual
recovery. Each invocation merges AT MOST one PR — the oldest ready one —
and stops; that merge alone triggers a new build-and-publish run, which
re-fires merge-queue.yml on completion to consider the next candidate.
Nothing here needs to loop or poll: the event-driven retrigger *is* the
loop. merge-queue.yml's own concurrency group additionally guarantees only
one invocation of this script is ever running at a time, so there's no
race between two runs both deciding the repo looks idle.

Must run inside a checkout of the Registry repo with GH_TOKEN in the
environment (gh CLI reads it itself; never passed as a literal argument).

Usage: merge_queue.py
"""
import json
import os
import subprocess
import sys

READY_CONCLUSIONS = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def run(*args: str) -> subprocess.CompletedProcess:
    """Runs a command and unconditionally prints what it was and what it
    produced, same as check_updates.py's helper of the same name — no
    secret is ever passed as a literal argument to anything run here."""
    print(f"+ {' '.join(args)}", file=sys.stderr)
    result = subprocess.run(args, check=False, capture_output=True, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout if result.stdout.endswith("\n") else result.stdout + "\n")
    if result.stderr:
        sys.stderr.write(result.stderr if result.stderr.endswith("\n") else result.stderr + "\n")
    return result


def repo_is_busy() -> bool:
    """True if any workflow run other than this queue-drain itself is
    currently queued or in progress anywhere in the repo. merge-queue runs
    are excluded from their own check (this invocation, and any other,
    are the controller — not something a merge needs to wait behind); a
    `gh run list` failure is treated as busy rather than as "go ahead",
    since a wrongly-skipped busy check is exactly the overlapping-merge
    bug this whole script exists to prevent."""
    own_run_id = os.environ.get("GITHUB_RUN_ID")
    for status in ("in_progress", "queued"):
        result = run("gh", "run", "list", "--status", status,
                     "--json", "databaseId,name", "--limit", "100")
        if result.returncode != 0:
            print(f"::warning::couldn't list {status} runs, assuming busy: {(result.stderr or '').strip()}", file=sys.stderr)
            return True
        for entry in json.loads(result.stdout or "[]"):
            if entry["name"] == "merge-queue" or str(entry["databaseId"]) == own_run_id:
                continue
            print(f"repo busy: {status} run '{entry['name']}' (#{entry['databaseId']})")
            return True
    return False


def find_ready_pr() -> int | None:
    """The oldest open bump/* PR whose own checks have all passed and has
    no merge conflict, or None if none qualify yet. Only bump/* branches
    are ever considered — that prefix is exclusively used by
    check_updates.py's autoPRs — so a human's own PR is never touched by
    this queue. A PR that isn't ready yet is skipped
    (not an error): trying the next-oldest candidate instead of blocking
    the whole queue behind one slow build keeps a big bundled PR from
    starving smaller, already-ready ones."""
    result = run("gh", "pr", "list", "--state", "open",
                 "--json", "number,headRefName,createdAt", "--limit", "100")
    if result.returncode != 0:
        print(f"::warning::couldn't list open PRs: {(result.stderr or '').strip()}", file=sys.stderr)
        return None
    prs = [p for p in json.loads(result.stdout or "[]") if p["headRefName"].startswith("bump/")]
    prs.sort(key=lambda p: p["createdAt"])

    for pr in prs:
        number = pr["number"]
        view = run("gh", "pr", "view", str(number),
                   "--json", "mergeable,statusCheckRollup")
        if view.returncode != 0:
            continue
        data = json.loads(view.stdout)
        if data.get("mergeable") != "MERGEABLE":
            print(f"PR #{number} isn't cleanly mergeable yet ({data.get('mergeable')}), skipping for now")
            continue
        rollup = data.get("statusCheckRollup") or []
        if not rollup:
            print(f"PR #{number} has no status checks reported yet, skipping for now")
            continue
        states = {c.get("conclusion") or c.get("state") for c in rollup}
        if states - READY_CONCLUSIONS:
            print(f"PR #{number} checks not all green yet ({states}), skipping for now")
            continue
        return number
    return None


def main() -> int:
    if repo_is_busy():
        print("another Actions run is in progress/queued — leaving the queue alone this time")
        return 0

    number = find_ready_pr()
    if number is None:
        print("no bump/* PR is ready to merge right now")
        return 0

    result = run("gh", "pr", "merge", str(number), "--rebase", "--delete-branch")
    if result.returncode != 0:
        print(f"::warning::failed to merge PR #{number}: {(result.stderr or '').strip()}", file=sys.stderr)
        return 0
    print(f"merged PR #{number}, branch deleted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
