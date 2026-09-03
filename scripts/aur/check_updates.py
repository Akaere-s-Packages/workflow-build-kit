#!/usr/bin/env python3
"""Find Registry packages with autoupdate=true that have a newer version on
AUR, group ones that hard-depend on each other into a single PR (one commit
per package, dependencies committed first, following the AOSC packaging
commit convention: "$pkgname: update to $pkgver"), and open one PR per
group. Packages with no dependency relationship to any other pending
update each get their own single-package PR.

If a group's branch already has an open PR, this doesn't open a second
one: it force-pushes the branch (rebuilt fresh from main, so it never
accumulates stale commits) with the current target versions and updates
the PR's title/body in place. If that branch is already at the exact
versions being targeted (e.g. two runs in a row with nothing new upstream
since the PR was opened), it's left untouched — no-op force-pushes and
duplicate work are both avoided.

Must run inside a checkout of the Registry repo, on branch "main", with
git user.name/user.email already configured and GH_TOKEN in the
environment (used by both `git push` over https and `gh pr create`/`edit`).
GH_TOKEN is read from the environment by git/gh themselves, never passed
as a literal argument, so it's safe that every command run here (with its
full stdout/stderr) is printed unconditionally for debugging.

Usage: check_updates.py --registry-root <path to the checkout>
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "registry"))
import aur_graph  # noqa: E402

BASE_BRANCH = "main"
RETRY_ATTEMPTS = 3
RETRY_DELAY_SECONDS = 5


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Runs a command and unconditionally prints what it was and what it
    produced — no secret is ever passed as a literal argument to anything
    run here, so there's nothing to redact. This is deliberately more
    verbose than the default: a previous version swallowed output on
    failure (capture_output + check=True raises before anything gets
    printed), which made a failed git/gh call show up as a bare Python
    traceback with no indication of what the command itself actually
    said."""
    print(f"+ {' '.join(args)}", file=sys.stderr)
    result = subprocess.run(args, check=False, capture_output=True, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout if result.stdout.endswith("\n") else result.stdout + "\n")
    if result.stderr:
        sys.stderr.write(result.stderr if result.stderr.endswith("\n") else result.stderr + "\n")
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result


def retry_run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Same as run(), but for the network-bound calls (git fetch/push,
    gh pr *) — worth surviving a transient GitHub/network blip rather
    than failing the whole run over one. Local-only git operations
    (checkout, add, commit, branch -D) don't need this."""
    result = None
    for n in range(1, RETRY_ATTEMPTS + 1):
        result = run(*args, check=False)
        if result.returncode == 0:
            return result
        if n < RETRY_ATTEMPTS:
            print(f"::warning::command failed (attempt {n}/{RETRY_ATTEMPTS}), retrying in {RETRY_DELAY_SECONDS}s: {' '.join(args)}", file=sys.stderr)
            time.sleep(RETRY_DELAY_SECONDS)
    if check and result.returncode != 0:
        print(f"::error::command failed after {RETRY_ATTEMPTS} attempts: {' '.join(args)}", file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result


def find_open_pr(branch: str) -> dict | None:
    result = retry_run("gh", "pr", "list", "--head", branch, "--state", "open", "--json", "number,title", check=False)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    prs = json.loads(result.stdout)
    return prs[0] if prs else None


def branch_file_version(branch: str, rel_path: str) -> str | None:
    """The `version = "..."` currently on `origin/<branch>` for that file,
    or None if the branch/file doesn't exist. Requires `origin/<branch>` to
    already be fetched. Purely local (reads the already-fetched ref from
    the local object database), so no retry needed."""
    result = run("git", "show", f"origin/{branch}:{rel_path}", check=False)
    if result.returncode != 0:
        return None
    m = re.search(r'version\s*=\s*"([^"]+)"', result.stdout)
    return m.group(1) if m else None


def process_group(group: set[str], dirty: dict[str, dict], depends_on: dict[str, set[str]], registry_root: pathlib.Path) -> None:
    ordered = aur_graph.topo_order(group, depends_on)
    branch = "bump/" + "+".join(ordered)

    existing_pr = find_open_pr(branch)

    if existing_pr:
        retry_run("git", "fetch", "origin", branch, check=False)
        already_current = all(
            branch_file_version(branch, str(dirty[name]["entry"]["toml_path"].relative_to(registry_root))) == dirty[name]["new_version"]
            for name in ordered
        )
        if already_current:
            print(f"branch {branch} (PR #{existing_pr['number']}) is already at the latest versions, nothing to do")
            return
        print(f"branch {branch} (PR #{existing_pr['number']}) exists but is stale — force-updating it in place")
    else:
        print(f"opening a new PR for {branch}")

    run("git", "checkout", BASE_BRANCH)
    run("git", "branch", "-D", branch, check=False)
    run("git", "checkout", "-b", branch)

    try:
        pr_body_lines = [
            "Opened automatically by the daily version-check run.",
        ]
        if len(ordered) > 1:
            pr_body_lines.append(f"Bundled because {', '.join(ordered)} depend on each other.")
        pr_body_lines.append("")

        for name in ordered:
            d = dirty[name]
            toml_path = d["entry"]["toml_path"]
            old_version = d["entry"]["version"]
            new_version = d["new_version"]

            old_text = toml_path.read_text()
            new_text = old_text.replace(f'version = "{old_version}"', f'version = "{new_version}"')
            if new_text == old_text:
                raise RuntimeError(f"couldn't find version = \"{old_version}\" in {toml_path}")
            toml_path.write_text(new_text)

            subject = f"{name}: update to {new_version}"
            run("git", "add", str(toml_path))
            run("git", "commit", "-m", subject)
            pr_body_lines.append(f"- `{subject}` — https://aur.archlinux.org/packages/{d['entry']['pkgbase']}")

        retry_run("git", "push", "--force", "origin", branch)

        if len(ordered) == 1:
            title = f"{ordered[0]}: update to {dirty[ordered[0]]['new_version']}"
        else:
            title = "; ".join(f"{n}: update to {dirty[n]['new_version']}" for n in ordered)
        body = "\n".join(pr_body_lines)

        if existing_pr:
            retry_run("gh", "pr", "edit", str(existing_pr["number"]), "--title", title, "--body", body)
            print(f"updated PR #{existing_pr['number']} ({branch})")
        else:
            pr = retry_run("gh", "pr", "create", "--title", title, "--body", body, "--head", branch, "--base", BASE_BRANCH)
            print(pr.stdout.strip())
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"::error::failed to prepare PR for {branch}: {exc}", file=sys.stderr)
    finally:
        run("git", "checkout", BASE_BRANCH)
        run("git", "branch", "-D", branch, check=False)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry-root", required=True, type=pathlib.Path)
    args = ap.parse_args()
    registry_root = args.registry_root.resolve()

    entries = aur_graph.load_registry(registry_root)
    candidates = [e for e in entries if e["autoupdate"] and e["enabled"]]

    if not candidates:
        print("no autoupdate packages configured")
        return 0

    try:
        aur_info = aur_graph.fetch_aur_info([e["name"] for e in candidates])
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::error::AUR RPC lookup failed: {exc}", file=sys.stderr)
        return 1

    dirty: dict[str, dict] = {}
    for e in candidates:
        info = aur_info.get(e["name"])
        if not info:
            print(f"::warning::AUR has no package named '{e['name']}' (pkgbase '{e['pkgbase']}'), skipping")
            continue
        upstream = info["Version"]
        if upstream != e["version"]:
            dirty[e["name"]] = {"entry": e, "info": info, "new_version": upstream}

    if not dirty:
        print("all autoupdate packages are already up to date")
        return 0

    dirty_entries = [d["entry"] for d in dirty.values()]
    depends_on = aur_graph.build_graph(dirty_entries, aur_info)

    for group in aur_graph.connected_components(set(dirty), depends_on):
        process_group(group, dirty, depends_on, registry_root)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
