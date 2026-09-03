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
import urllib.parse
import urllib.request

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

AUR_RPC = "https://aur.archlinux.org/rpc/v5/info"
BASE_BRANCH = "main"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, capture_output=True, text=True)


def load_registry(root: pathlib.Path) -> list[dict]:
    # Layout: <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
    entries = []
    for toml_path in sorted(root.glob("*/*/*/*.toml")):
        distro, source_type, dirname, filename = toml_path.parts[-4:]
        if filename != f"{dirname}.toml":
            continue
        table = tomllib.loads(toml_path.read_text())["PACKAGES"]
        entries.append(
            {
                "distro": distro,
                "type": source_type,
                "name": table["name"],
                "pkgbase": table.get("pkgbase", table["name"]),
                "version": table["version"],
                "autoupdate": bool(table.get("autoupdate", False)),
                "enabled": bool(table.get("enabled", True)),
                "toml_path": toml_path,
            }
        )
    return entries


def fetch_aur_info(pkgbases: list[str]) -> dict[str, dict]:
    if not pkgbases:
        return {}
    qs = "&".join("arg[]=" + urllib.parse.quote(b) for b in sorted(set(pkgbases)))
    with urllib.request.urlopen(f"{AUR_RPC}?{qs}", timeout=30) as resp:
        data = json.load(resp)
    return {r["Name"]: r for r in data.get("results", [])}


def strip_version_constraint(dep: str) -> str:
    for sep in (">=", "<=", "=", ">", "<"):
        dep = dep.split(sep, 1)[0]
    return dep


def dep_names(info: dict) -> set[str]:
    # Only hard Depends/MakeDepends count as a real "A depends on B"
    # relationship for grouping purposes — OptDepends is a soft suggestion,
    # not a requirement, and bundling PRs over one would be overreach.
    names = set()
    for field in ("Depends", "MakeDepends"):
        for dep in info.get(field) or []:
            names.add(strip_version_constraint(dep))
    return names


def connected_components(nodes: set[str], edges: dict[str, set[str]]) -> list[set[str]]:
    seen: set[str] = set()
    components = []
    for start in nodes:
        if start in seen:
            continue
        stack = [start]
        component: set[str] = set()
        while stack:
            n = stack.pop()
            if n in component:
                continue
            component.add(n)
            neighbors = edges.get(n, set()) | {m for m, es in edges.items() if n in es}
            stack.extend(neighbors - component)
        seen |= component
        components.append(component)
    return components


def topo_order(names: set[str], depends_on: dict[str, set[str]]) -> list[str]:
    """Dependencies first (post-order DFS). Tolerates cycles — real
    packages shouldn't have any, but PKGBUILDs are user-authored data we
    don't control, so a cycle degrades to visiting nodes in whatever order
    the guard lets it, rather than crashing."""
    order: list[str] = []
    visited: set[str] = set()
    in_progress: set[str] = set()

    def visit(n: str) -> None:
        if n in visited or n in in_progress:
            return
        in_progress.add(n)
        for dep in sorted(depends_on.get(n, set()) & names):
            visit(dep)
        in_progress.discard(n)
        visited.add(n)
        order.append(n)

    for n in sorted(names):
        visit(n)
    return order


def process_group(group: set[str], dirty: dict[str, dict], depends_on: dict[str, set[str]]) -> None:
    ordered = topo_order(group, depends_on)
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

    entries = load_registry(args.registry_root)
    candidates = [e for e in entries if e["autoupdate"] and e["enabled"]]

    if not candidates:
        print("no autoupdate packages configured")
        return 0

    try:
        aur_info = fetch_aur_info([e["pkgbase"] for e in candidates])
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

    depends_on = {name: dep_names(d["info"]) & dirty.keys() for name, d in dirty.items()}
    edges = {name: deps for name, deps in depends_on.items() if deps}

    for group in connected_components(set(dirty), edges):
        process_group(group, dirty, depends_on)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
