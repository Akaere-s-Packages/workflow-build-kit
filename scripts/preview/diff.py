#!/usr/bin/env python3
"""Print a Markdown PR-comment body comparing a freshly built package
against what's currently published — read from WebSite-Kit's public
packageDetails JSON on GitHub Pages. No MinIO/GPG credentials needed: this
job is deliberately secret-free so it's safe to run even on PRs from forks.

Usage:
  diff.py --name asusctl --old-version 6.4.0-1 --new-version 6.4.1-1
          --build-status success --job-url <url>
          --file-list <path to file_list.json>  # only when build-status=success
          --published-base-url https://packages.pysio.online
"""
import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request


def fetch_published(base_url: str, name: str) -> dict | None:
    """Returns the published packageDetails, or None if there is none yet
    (a genuine 404) *or* the fetch failed for any other reason (network
    hiccup, site briefly down, ...). Either way the diff degrades to
    "nothing to compare against" rather than crashing the whole PR check —
    this job has no credentials to fall back on, so best-effort is all it
    can do."""
    url = f"{base_url.rstrip('/')}/packageDetails/{name}.json"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            print(f"::warning::couldn't fetch published data for {name} ({exc}), diffing against nothing", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::warning::couldn't fetch published data for {name} ({exc}), diffing against nothing", file=sys.stderr)
        return None


# GitHub rejects an issue/PR comment body over 65536 characters outright
# (real failure: visual-studio-code-bin's diff — ~9000 files, nearly all
# of them re-sized by the version bump — produced a ~270000-char table and
# the whole `comment` job step failed with a 422). The rest of this
# comment (header/version/status/size-summary/anchor) is at most a few
# hundred characters, so budgeting well under the real limit for the table
# rows leaves a large, safe margin regardless of how many packages this PR
# touches or how long their paths are.
MAX_ROWS_CHARS = 55000


def fmt_delta(n: int) -> str:
    sign = "+" if n >= 0 else "-"
    n = abs(n)
    val = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if val < 1024 or unit == "GB":
            return f"{sign}{val:.0f} {unit}" if unit == "B" else f"{sign}{val:.1f} {unit}"
        val /= 1024
    return f"{sign}{val:.1f} GB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--old-version", default="")
    ap.add_argument("--new-version", required=True)
    ap.add_argument("--build-status", choices=["success", "failure"], required=True)
    ap.add_argument("--job-url", required=True)
    ap.add_argument("--file-list", type=pathlib.Path)
    ap.add_argument("--published-base-url", required=True)
    args = ap.parse_args()

    anchor = f"<!-- workflow-build-kit:{args.name} -->"
    lines = [f"### \U0001F4E6 {args.name} build preview", ""]
    lines.append(f"Version: `{args.old_version or '(new)'}` -> `{args.new_version}`")

    if args.build_status == "failure":
        lines.append(f"Build: FAILED ([view log]({args.job_url}))")
        lines.append("")
        lines.append(anchor)
        print("\n".join(lines))
        return 0

    lines.append(f"Build: succeeded ([view log]({args.job_url}))")
    lines.append("")

    new_data = json.loads(args.file_list.read_text()) if args.file_list and args.file_list.exists() else {"files": [], "package_size_bytes": 0}
    new_files = {f["path"]: f["size_bytes"] for f in new_data.get("files", [])}
    new_total = new_data.get("package_size_bytes") or sum(new_files.values())

    published = fetch_published(args.published_base_url, args.name)
    old_files = {f["path"]: f["size_bytes"] for f in (published or {}).get("files", [])}
    old_total = (published or {}).get("package_size_bytes") or sum(old_files.values())

    rows = []
    for path in sorted(set(new_files) - set(old_files)):
        rows.append(f"| added | `{path}` | {fmt_delta(new_files[path])} |")
    for path in sorted(set(old_files) - set(new_files)):
        rows.append(f"| removed | `{path}` | {fmt_delta(-old_files[path])} |")
    for path in sorted(set(new_files) & set(old_files)):
        if new_files[path] != old_files[path]:
            rows.append(f"| changed | `{path}` | {fmt_delta(new_files[path] - old_files[path])} |")

    if rows:
        lines.append("| Status | File | Size change |")
        lines.append("|---|---|---|")
        shown, budget, omitted = [], MAX_ROWS_CHARS, 0
        for row in rows:
            if budget - (len(row) + 1) < 0:
                omitted += 1
                continue
            shown.append(row)
            budget -= len(row) + 1
        lines.extend(shown)
        if omitted:
            noun = "file" if omitted == 1 else "files"
            lines.append(f"| _(truncated)_ | _{omitted} more {noun} not shown — comment size limit_ | |")
        lines.append("")
    elif published is None:
        lines.append("_(no published version to compare against yet — these are all of this package's files)_")
        lines.append("")

    lines.append(f"Package size: {old_total / 1024 / 1024:.1f} MB -> {new_total / 1024 / 1024:.1f} MB ({fmt_delta(new_total - old_total)})")
    lines.append("")
    lines.append(anchor)

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
