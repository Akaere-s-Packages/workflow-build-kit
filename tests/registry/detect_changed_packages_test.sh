#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tmp="$(mktemp -d)"
diff_tmp=""
trap 'rm -rf "$tmp" "$diff_tmp"' EXIT

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

# base-ref/head-ref mode must exclude a DELETED package entirely — not
# report it as "changed". resolve_build_order.py hard-fails the whole run
# on any name that doesn't resolve back to a live Registry entry, so a
# deleted toml showing up here would break every other package's build in
# the same push too, not just fail to clean up. Removed packages still get
# cleaned out of the published repo db — separately, by the publish job
# reconciling the current Registry tree against the db (see
# prune_removed_packages in repo_lib.sh) — this script only decides what
# needs BUILDING.
diff_tmp="$(mktemp -d)"
git -C "$diff_tmp" init -q -b main
git -C "$diff_tmp" config user.email test@example.com
git -C "$diff_tmp" config user.name test
mkdir -p "$diff_tmp/archlinux/aur/pkg-a" "$diff_tmp/archlinux/aur/pkg-b"
printf '%s\n' '[PACKAGES]' 'name = "pkg-a"' > "$diff_tmp/archlinux/aur/pkg-a/pkg-a.toml"
printf '%s\n' '[PACKAGES]' 'name = "pkg-b"' > "$diff_tmp/archlinux/aur/pkg-b/pkg-b.toml"
git -C "$diff_tmp" add -A
git -C "$diff_tmp" commit -q -m base
base_sha="$(git -C "$diff_tmp" rev-parse HEAD)"

rm "$diff_tmp/archlinux/aur/pkg-b/pkg-b.toml"
rmdir "$diff_tmp/archlinux/aur/pkg-b"
printf '%s\n' '[PACKAGES]' 'name = "pkg-a"' 'autoupdate = true' > "$diff_tmp/archlinux/aur/pkg-a/pkg-a.toml"
git -C "$diff_tmp" add -A
git -C "$diff_tmp" commit -q -m "bump pkg-a, remove pkg-b"
head_sha="$(git -C "$diff_tmp" rev-parse HEAD)"

diff_actual="$(cd "$diff_tmp" && "$repo_root/scripts/registry/detect_changed_packages.sh" "$base_sha" "$head_sha")"
diff_expected='[{"distro": "archlinux", "type": "aur", "name": "pkg-a", "path": "archlinux/aur/pkg-a/pkg-a.toml"}]'
[[ "$diff_actual" == "$diff_expected" ]] || {
  echo "FAIL: expected deleted pkg-b excluded, got $diff_actual" >&2
  exit 1
}
echo "changed-package detection tests passed"
