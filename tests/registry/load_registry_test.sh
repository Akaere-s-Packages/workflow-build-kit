#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/registry/load_registry.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/archlinux/aur/foo" "$tmp/archlinux/aur/foo-common" "$tmp/archlinux/aur/bar"
printf '%s\n' '[PACKAGES]' 'name = "foo"' 'version = "1.0-1"' 'autoupdate = true' \
  'pkgbase = "foobase"' 'aur_depends = ["dep-a", "dep-b"]' > "$tmp/archlinux/aur/foo/foo.toml"
printf '%s\n' '[PACKAGES]' 'name = "foo-common"' 'version = "1.0-1"' 'autoupdate = false' 'enabled = false' \
  > "$tmp/archlinux/aur/foo-common/foo-common.toml"
printf '%s\n' '[PACKAGES]' 'name = "bar"' 'version = "2.0-1"' 'autoupdate = true' > "$tmp/archlinux/aur/bar/bar.toml"

out="$("$script" --registry-root "$tmp")"

# --- ordering: "foo" before "foo-common", matching Python pathlib's
# part-tuple comparison (see detect_changed_packages_test.sh for the
# real-world case this guards — samsung-unified-driver vs
# samsung-unified-driver-common) ---
names="$(jq -c '[.[].name]' <<<"$out")"
[[ "$names" == '["bar","foo","foo-common"]' ]] || fail "expected bar,foo,foo-common order, got $names"

# --- field extraction, including defaults ---
foo="$(jq -c '.[] | select(.name == "foo")' <<<"$out")"
[[ "$(jq -r '.pkgbase' <<<"$foo")" == "foobase" ]] || fail "foo pkgbase: $foo"
[[ "$(jq -r '.enabled' <<<"$foo")" == "true" ]] || fail "foo enabled should default to true: $foo"

fc="$(jq -c '.[] | select(.name == "foo-common")' <<<"$out")"
[[ "$(jq -r '.pkgbase' <<<"$fc")" == "foo-common" ]] || fail "foo-common pkgbase should default to name: $fc"
[[ "$(jq -r '.enabled' <<<"$fc")" == "false" ]] || fail "foo-common enabled=false should be preserved: $fc"
[[ "$(jq -r '.autoupdate' <<<"$fc")" == "false" ]] || fail "foo-common autoupdate: $fc"

# --- toml_path is absolute ---
[[ "$(jq -r '.toml_path' <<<"$foo")" == "$tmp/archlinux/aur/foo/foo.toml" ]] || fail "toml_path should be absolute: $foo"

echo "load_registry.sh tests passed"
