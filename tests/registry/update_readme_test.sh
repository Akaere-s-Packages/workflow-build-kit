#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/registry/update_readme.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

reg="$tmp/registry"
mkdir -p "$reg/archlinux/aur/foo" "$reg/archlinux/aur/foo-common"
printf '%s\n' '[PACKAGES]' 'name = "foo"' 'version = "1.0-1"' 'autoupdate = true' > "$reg/archlinux/aur/foo/foo.toml"
printf '%s\n' '[PACKAGES]' 'name = "foo-common"' 'version = "2.0-1"' 'autoupdate = false' > "$reg/archlinux/aur/foo-common/foo-common.toml"
cat > "$reg/README.md" <<'EOF'
# My Registry

Some intro text.

<!-- PACKAGE_TABLE:START -->
placeholder
<!-- PACKAGE_TABLE:END -->

Footer text stays untouched.
EOF

# --- missing markers: hard error, exit 1 ---
no_markers="$tmp/no_markers"
mkdir -p "$no_markers"
printf '# no markers here\n' > "$no_markers/README.md"
set +e
"$script" --registry-root "$no_markers" >/tmp/no_markers_out 2>&1
status=$?
set -e
[[ $status -eq 1 ]] || fail "missing markers should exit 1"
grep -q "must already contain" /tmp/no_markers_out || fail "expected marker-requirement error"
rm -f /tmp/no_markers_out

# --- normal run: table generated, ordering matches path-component
# comparison (foo before foo-common — the flat-string-sort trap this
# guards, see detect_changed_packages_test.sh for the real-world case) ---
"$script" --registry-root "$reg" --pages-domain example.com > /tmp/update_readme_out
grep -q "updated README.md package table (2 packages)" /tmp/update_readme_out || fail "expected update message: $(cat /tmp/update_readme_out)"
rm -f /tmp/update_readme_out

foo_line="$(grep '| foo ' "$reg/README.md")"
foo_common_line="$(grep '| foo-common ' "$reg/README.md")"
[[ "$foo_line" == *"| archlinux | aur | 1.0-1 | yes |"* ]] || fail "foo row: $foo_line"
[[ "$foo_common_line" == *"| archlinux | aur | 2.0-1 | no |"* ]] || fail "foo-common row: $foo_common_line"
[[ "$foo_line" == *"[details](https://example.com/packages/foo/)"* ]] || fail "foo details link: $foo_line"

foo_pos="$(grep -n '| foo ' "$reg/README.md" | cut -d: -f1)"
foo_common_pos="$(grep -n '| foo-common ' "$reg/README.md" | cut -d: -f1)"
(( foo_pos < foo_common_pos )) || fail "expected foo row before foo-common row"

grep -q "Footer text stays untouched." "$reg/README.md" || fail "content after END marker must be preserved"
grep -q "# My Registry" "$reg/README.md" || fail "content before START marker must be preserved"

# --- second run with no changes: no-op message, file untouched ---
before_hash="$(sha256sum "$reg/README.md")"
out2="$("$script" --registry-root "$reg" --pages-domain example.com)"
[[ "$out2" == "README.md package table already up to date" ]] || fail "expected no-op message, got: $out2"
after_hash="$(sha256sum "$reg/README.md")"
[[ "$before_hash" == "$after_hash" ]] || fail "README.md should be byte-identical after a no-op run"

echo "update_readme.sh tests passed"
