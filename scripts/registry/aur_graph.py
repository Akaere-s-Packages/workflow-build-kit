#!/usr/bin/env python3
"""Shared dependency-graph helpers for Registry packages, built from live
AUR RPC data. Used by both check_updates.py (group related version bumps
into one PR) and resolve_build_order.py (expand a changed-package set to
everything that needs rebuilding, in dependency order).

Only hard Depends/MakeDepends count as a real "A needs B" edge —
OptDepends is a soft suggestion, not a requirement, and grouping/ordering
builds over one would be overreach. This is a project-wide convention, not
just a detail of one script: keep it consistent everywhere a dependency
graph gets built.
"""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

AUR_RPC = "https://aur.archlinux.org/rpc/v5/info"
RETRY_ATTEMPTS = 3
RETRY_DELAY_SECONDS = 5


def load_registry(root: pathlib.Path) -> list[dict]:
    """Layout: <distro>/<type>/<name>/<name>.toml, e.g.
    archlinux/aur/asusctl/asusctl.toml."""
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


def fetch_aur_info(names: list[str]) -> dict[str, dict]:
    """One batched AUR RPC call, queried by package *name* (not pkgbase —
    a split PKGBUILD's several pkgnames each have their own Depends/
    MakeDepends, and AUR RPC's info action is queryable by the specific
    name). Returns a dict keyed by that same name.

    Retries a few times before giving up — a transient AUR RPC hiccup
    shouldn't take down every script that calls this (version checks,
    build ordering) on the first blip."""
    if not names:
        return {}
    qs = "&".join("arg[]=" + urllib.parse.quote(n) for n in sorted(set(names)))
    url = f"{AUR_RPC}?{qs}"
    last_exc: Exception | None = None
    for n in range(1, RETRY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = json.load(resp)
            return {r["Name"]: r for r in data.get("results", [])}
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_exc = exc
            if n < RETRY_ATTEMPTS:
                print(f"::warning::AUR RPC lookup failed (attempt {n}/{RETRY_ATTEMPTS}), retrying in {RETRY_DELAY_SECONDS}s: {exc}", file=sys.stderr)
                time.sleep(RETRY_DELAY_SECONDS)
    print(f"::warning::AUR RPC lookup failed after {RETRY_ATTEMPTS} attempts, continuing with no AUR data: {last_exc}", file=sys.stderr)
    return {}


def strip_version_constraint(dep: str) -> str:
    for sep in (">=", "<=", "=", ">", "<"):
        dep = dep.split(sep, 1)[0]
    return dep


def dep_names(info: dict) -> set[str]:
    """Hard Depends/MakeDepends only — see module docstring."""
    names = set()
    for field in ("Depends", "MakeDepends"):
        for dep in info.get(field) or []:
            names.add(strip_version_constraint(dep))
    return names


def build_graph(entries: list[dict], aur_info: dict[str, dict]) -> dict[str, set[str]]:
    """name -> set of names it hard-depends on, restricted to names we
    ourselves track (an AUR dependency we don't track as a Registry
    package is irrelevant to grouping/ordering our own builds)."""
    tracked = {e["name"] for e in entries}
    depends_on: dict[str, set[str]] = {}
    for e in entries:
        info = aur_info.get(e["name"], {})
        depends_on[e["name"]] = dep_names(info) & tracked - {e["name"]}
    return depends_on


def connected_components(nodes: set[str], depends_on: dict[str, set[str]]) -> list[set[str]]:
    """Undirected connectivity over a directed graph restricted to `nodes`
    — grouping only cares "are these related", direction is handled
    separately by topo_order/layered_order."""
    edges = {n: (depends_on.get(n, set()) & nodes) for n in nodes}
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
    """Dependencies first (post-order DFS), flattened into a single list.
    Tolerates cycles — real packages shouldn't have any, but PKGBUILDs are
    user-authored data we don't control, so a cycle degrades to visiting
    nodes in whatever order the guard lets it, rather than crashing."""
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


def layered_order(names: set[str], depends_on: dict[str, set[str]], max_layers: int) -> list[list[str]]:
    """Kahn's-algorithm layering: layer 0 is everything in `names` whose
    dependencies (restricted to `names`) are all outside `names` (i.e.
    already satisfied); each later layer depends only on earlier layers.
    Packages with no relation to anything else all land in layer 0 and
    build in parallel there.

    Raises ValueError if the graph needs more layers than max_layers (a
    real cycle among tracked packages, or a dependency chain deeper than
    expected) — surface that loudly instead of silently misordering.
    """
    remaining = set(names)
    placed: set[str] = set()
    layers: list[list[str]] = []

    while remaining:
        if len(layers) >= max_layers:
            raise ValueError(
                f"dependency graph among {sorted(names)} needs more than {max_layers} build layers "
                f"(unplaced: {sorted(remaining)}) — likely a cycle, or a chain deeper than expected"
            )
        layer = sorted(n for n in remaining if (depends_on.get(n, set()) & names) <= placed)
        if not layer:
            raise ValueError(
                f"cannot make progress ordering {sorted(remaining)} — dependency cycle among tracked packages"
            )
        layers.append(layer)
        placed |= set(layer)
        remaining -= set(layer)

    return layers
