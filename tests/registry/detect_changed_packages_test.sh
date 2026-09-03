#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/archlinux/aur/pkg-a" "$tmp/archlinux/aur/pkg-b"
printf '%s\n' '[PACKAGES]' 'name = "pkg-a"' > "$tmp/archlinux/aur/pkg-a/pkg-a.toml"
printf '%s\n' '[PACKAGES]' 'name = "pkg-b"' > "$tmp/archlinux/aur/pkg-b/pkg-b.toml"
printf '%s\n' \
  '[{"title":"[build-failure] pkg-b"},{"title":"manual issue"},{"title":"[build-failure] missing"},{"title":"[build-failure] pkg-a"}]' |
  jq '[.[].title | select(startswith("[build-failure] ")) | ltrimstr("[build-failure] ")]' > "$tmp/failed.json"

actual="$(cd "$tmp" && "$repo_root/scripts/registry/detect_changed_packages.sh" --names failed.json)"
expected='[{"distro": "archlinux", "type": "aur", "name": "pkg-a", "path": "archlinux/aur/pkg-a/pkg-a.toml"}, {"distro": "archlinux", "type": "aur", "name": "pkg-b", "path": "archlinux/aur/pkg-b/pkg-b.toml"}]'

[[ "$actual" == "$expected" ]] || {
  echo "FAIL: expected $expected, got $actual" >&2
  exit 1
}

all_actual="$(cd "$tmp" && "$repo_root/scripts/registry/detect_changed_packages.sh" --all)"
[[ "$all_actual" == "$expected" ]] || {
  echo "FAIL: expected all packages $expected, got $all_actual" >&2
  exit 1
}

echo "changed-package detection tests passed"
