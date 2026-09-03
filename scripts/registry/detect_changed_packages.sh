#!/usr/bin/env bash
set -euo pipefail

# Prints a JSON array of {"distro","type","name","path"} for Registry
# packages. Must be run from inside a checkout of the Registry repo.
#
# Layout: <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
#
# Two modes:
#   detect_changed_packages.sh <base-ref> <head-ref>   only what changed
#                                                       between two refs
#                                                       (needs fetch-depth: 0)
#   detect_changed_packages.sh --all                   every package in the
#                                                       registry, regardless
#                                                       of git history — for
#                                                       a manual full rebuild

if [[ "${1:-}" == "--all" ]]; then
  python3 - <<'PY'
import json
import pathlib

packages = []
for toml_path in sorted(pathlib.Path(".").glob("*/*/*/*.toml")):
    distro, source_type, name, filename = toml_path.parts[-4:]
    if filename != f"{name}.toml":
        continue
    packages.append({"distro": distro, "type": source_type, "name": name, "path": str(toml_path)})

print(json.dumps(packages))
PY
  exit 0
fi

base_ref="${1:?base ref required (or pass --all to list every package)}"
head_ref="${2:?head ref required}"

changed="$(git diff --name-only "$base_ref" "$head_ref" -- '*/*/*/*.toml' || true)"

if [[ -z "$changed" ]]; then
  echo '[]'
  exit 0
fi

python3 - "$changed" <<'PY'
import json
import sys

lines = [l for l in sys.argv[1].splitlines() if l.strip()]
packages = []
for path in lines:
    parts = path.split("/")
    if len(parts) != 4:
        continue
    distro, source_type, name, filename = parts
    if filename != f"{name}.toml":
        continue
    packages.append({"distro": distro, "type": source_type, "name": name, "path": path})

print(json.dumps(packages))
PY
