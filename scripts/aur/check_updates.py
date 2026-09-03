#!/usr/bin/env python3
"""Find Registry packages with autoupdate=true that have a newer version on
AUR, group ones that hard-depend on each other into a single PR (one commit
per package, dependencies committed first, following the AOSC packaging
commit convention: "$pkgname: update to $pkgver"), and open one PR per
group. Packages with no dependency relationship to any other pending
update each get their own single-package PR.

Must run inside a checkout of the Registry repo, on branch "main", with
git user.name/user.email already configured and GH_TOKEN in the
environment (used by both `git push` over https and `gh pr create`).

Usage: check_updates.py --registry-root <path to the checkout>
"""
import argparse
import json
import pathlib
import subprocess
import sys
import urllib.error

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "registry"))
import aur_graph  # noqa: E402

BASE_BRANCH = "main"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, capture_output=True, text=True)


def process_group(group: set[str], dirty: dict[str, dict], depends_on: dict[str, set[str]]) -> None:
    ordered = aur_graph.topo_order(group, depends_on)
    branch = "bump/" + "+".join(ordered)

    exists = run("git", "ls-remote", "--exit-code", "--heads", "origin", branch, check=False)
    if exists.returncode == 0:
        print(f"branch {branch} already exists, skipping (a PR is presumably already open)")
        return

    run("git", "checkout", BASE_BRANCH)
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

        run("git", "push", "origin", branch)

        if len(ordered) == 1:
            title = f"{ordered[0]}: update to {dirty[ordered[0]]['new_version']}"
        else:
            title = "; ".join(f"{n}: update to {dirty[n]['new_version']}" for n in ordered)

        pr = run("gh", "pr", "create", "--title", title, "--body", "\n".join(pr_body_lines),
                  "--head", branch, "--base", BASE_BRANCH)
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

    entries = aur_graph.load_registry(args.registry_root)
    candidates = [e for e in entries if e["autoupdate"] and e["enabled"]]

    if not candidates:
        print("no autoupdate packages configured")
        return 0

    try:
        aur_info = aur_graph.fetch_aur_info([e["pkgbase"] for e in candidates])
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::error::AUR RPC lookup failed: {exc}", file=sys.stderr)
        return 1

    dirty: dict[str, dict] = {}
    for e in candidates:
        info = aur_info.get(e["pkgbase"])
        if not info:
            print(f"::warning::AUR has no package '{e['pkgbase']}', skipping {e['name']}")
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
        process_group(group, dirty, depends_on)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
