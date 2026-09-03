#!/usr/bin/env python3
"""Expand a set of changed packages to everything that needs building
alongside them, and lay the result out in dependency-ordered build layers.

Given the packages that literally changed in this push/PR (from
detect_changed_packages.sh), this:
  1. Fetches live AUR dependency data for every package in the Registry
     (not just the changed ones — a changed package might be a dependency
     *of* something unchanged, and that something needs to be pulled in
     too, e.g. bumping asusctl should also rebuild rog-control-center
     since it hard-depends on asusctl).
  2. Finds every package connected (via hard Depends/MakeDepends) to a
     changed package, unions those into the full build set.
  3. Lays the build set out into ordered layers ("waves"): layer 0 has no
     unbuilt dependency within the set and can build in parallel; each
     later layer depends only on earlier ones.

Usage:
  resolve_build_order.py --registry-root <path> --changed <json-file-or-'-'>
                          [--max-layers 3]

--changed points at a JSON file with the same shape
detect_changed_packages.sh prints (an array of {"distro","type","name","path"});
pass '-' to read that JSON from stdin instead.

Prints a JSON array of layers, each layer itself an array of package
objects: [[{...}, {...}], [{...}]]. An empty overall result prints [[]].
"""
import argparse
import json
import pathlib
import sys
import urllib.error

import aur_graph

DEFAULT_MAX_LAYERS = 3


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry-root", required=True, type=pathlib.Path)
    ap.add_argument("--changed", required=True, help="path to detect_changed_packages.sh's JSON output, or '-' for stdin")
    ap.add_argument("--max-layers", type=int, default=DEFAULT_MAX_LAYERS)
    args = ap.parse_args()

    changed_raw = sys.stdin.read() if args.changed == "-" else pathlib.Path(args.changed).read_text()
    changed = json.loads(changed_raw)
    changed_names = {p["name"] for p in changed}

    if not changed_names:
        print(json.dumps([[]] * args.max_layers))
        return 0

    entries = aur_graph.load_registry(args.registry_root)
    by_name = {e["name"]: e for e in entries}

    unknown = changed_names - by_name.keys()
    if unknown:
        print(f"::error::changed package(s) not found in registry: {sorted(unknown)}", file=sys.stderr)
        return 1

    try:
        aur_info = aur_graph.fetch_aur_info([e["pkgbase"] for e in entries])
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::warning::AUR RPC lookup failed ({exc}), building only the literally-changed packages with no expansion", file=sys.stderr)
        print(json.dumps([changed] + [[]] * (args.max_layers - 1)))
        return 0

    depends_on = aur_graph.build_graph(entries, aur_info)
    all_names = set(by_name)

    build_set: set[str] = set()
    for component in aur_graph.connected_components(all_names, depends_on):
        if component & changed_names:
            build_set |= component

    try:
        layers = aur_graph.layered_order(build_set, depends_on, max_layers=args.max_layers)
    except ValueError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    result = [[by_name[name] for name in layer if by_name[name]] for layer in layers]
    # Emit the same {"distro","type","name","path"} shape detect_changed_packages.sh
    # uses, not the full registry entry (drop version/autoupdate/toml_path/etc.).
    result = [
        [{"distro": e["distro"], "type": e["type"], "name": e["name"], "path": str(e["toml_path"].relative_to(args.registry_root))} for e in layer]
        for layer in result
    ]
    # Always pad to exactly max_layers entries (with empty layers) so the
    # calling workflow can index layers[0]/[1]/[2] unconditionally instead
    # of having to guard against a shorter-than-expected array.
    while len(result) < args.max_layers:
        result.append([])
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
