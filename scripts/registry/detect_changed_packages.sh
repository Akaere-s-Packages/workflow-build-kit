#!/usr/bin/env bash
set -euo pipefail

# Prints a JSON array of {"distro","type","name","path"} for every Registry
# package TOML that changed between two refs. Must be run from inside a
# checkout of the Registry repo with enough history to diff (fetch-depth: 0).
#
# Layout: <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
#
# Usage: detect_changed_packages.sh <base-ref> <head-ref>

base_ref="${1:?base ref required}"
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
