#!/usr/bin/env bash
set -euo pipefail

# Exercises the file_list.json / build_meta.json generation tail of
# backends/archlinux/build.sh in isolation (extracted by sed, same
# technique tests/publish/publish_all_test.sh uses) — this is the part
# that used to be two python3 heredocs and is now hand-written awk/jq, so
# it's the highest-value part of build.sh to verify directly rather than
# only indirectly through a full makepkg run.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- build a fake package: .PKGINFO with a representative mix of fields,
# plus real installed files at various depths (including one whose name
# starts with "." to prove the bookkeeping-file exclusion still works on
# a REAL content file, not just the actual .PKGINFO/.MTREE/.BUILDINFO
# entries) and a directory entry (which bsdtar also lists, and which must
# be excluded the same way pacman's own bookkeeping entries are). ---
pkgroot="$tmp/pkgroot"
mkdir -p "$pkgroot/opt/testpkg" "$pkgroot/usr/bin"
cat > "$pkgroot/.PKGINFO" <<'EOF'
pkgname = testpkg
pkgbase = testpkg
pkgver = 1.0-1
pkgdesc = A test package for build.sh's own test suite
url = https://example.com/testpkg
packager = Test Packager <test@example.com>
arch = x86_64
license = MIT
license = Apache-2.0
depend = glibc>=2.31
depend = some-aur-only-dep
optdepend = foo-tool: needed for the bar feature
makedepend = cmake
EOF
printf 'binary-ish content' > "$pkgroot/opt/testpkg/testpkg"
printf '#!/bin/sh\necho hi\n' > "$pkgroot/usr/bin/testpkg-wrapper"
printf 'dotfile that is real package content, not bookkeeping' > "$pkgroot/opt/testpkg/.hidden-config"

pkg_file="$tmp/testpkg-1.0-1-x86_64.pkg.tar.zst"
( cd "$pkgroot" && bsdtar -cf - .PKGINFO opt usr | zstd -q -o "$pkg_file" )

out_dir="$tmp/out"
mkdir -p "$out_dir"

# A fake `pacman` on PATH: reports glibc as a real "core" repo package,
# everything else (including some-aur-only-dep) as "not found" — the exact
# shape the real classify logic needs to distinguish "aur" (default, not
# found in any sync repo) from an actual sync-repo classification.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
if [[ "$1" == "-Si" && "$2" == "glibc" ]]; then
  echo "Repository      : core"
  exit 0
fi
exit 1
PACMAN
chmod +x "$tmp/bin/pacman"

sed -n '/^# --- file list/,$p' "$repo_root/backends/archlinux/build.sh" > "$tmp/tail.sh"
(
  export PATH="$tmp/bin:$PATH"
  export pkg_file out_dir
  bash -c 'set -euo pipefail; source "$1"' _ "$tmp/tail.sh"
)

# --- file_list.json ---
[[ -f "$out_dir/file_list.json" ]] || fail "file_list.json was not written"
file_paths="$(jq -r '.files[].path' "$out_dir/file_list.json" | sort)"
expected_paths=$'/opt/testpkg/.hidden-config\n/opt/testpkg/testpkg\n/usr/bin/testpkg-wrapper'
[[ "$file_paths" == "$expected_paths" ]] || fail "file_list.json paths: expected [$expected_paths], got [$file_paths]"

# .PKGINFO itself, and the two directory entries (opt/, opt/testpkg/,
# usr/, usr/bin/), must never appear as files.
jq -e '.files[] | select(.path | test("PKGINFO"))' "$out_dir/file_list.json" >/dev/null 2>&1 &&
  fail ".PKGINFO leaked into file_list.json"
dir_count="$(jq -r '.files[].path' "$out_dir/file_list.json" | grep -c '/$' || true)"
[[ "$dir_count" -eq 0 ]] || fail "a directory entry leaked into file_list.json"

expected_total=$(( $(stat -c%s "$pkgroot/opt/testpkg/testpkg") + $(stat -c%s "$pkgroot/usr/bin/testpkg-wrapper") + $(stat -c%s "$pkgroot/opt/testpkg/.hidden-config") ))
actual_total="$(jq -r '.package_size_bytes' "$out_dir/file_list.json")"
[[ "$actual_total" == "$expected_total" ]] || fail "package_size_bytes: expected $expected_total, got $actual_total"

# --- build_meta.json ---
[[ -f "$out_dir/build_meta.json" ]] || fail "build_meta.json was not written"
[[ ! -f "$out_dir/.PKGINFO.raw" ]] || fail ".PKGINFO.raw should be cleaned up"

meta="$(cat "$out_dir/build_meta.json")"
[[ "$(jq -r '.description' <<<"$meta")" == "A test package for build.sh's own test suite" ]] || fail "description: $meta"
[[ "$(jq -r '.url' <<<"$meta")" == "https://example.com/testpkg" ]] || fail "url: $meta"
[[ "$(jq -r '.packager' <<<"$meta")" == "Test Packager <test@example.com>" ]] || fail "packager: $meta"
[[ "$(jq -c '.licenses' <<<"$meta")" == '["MIT","Apache-2.0"]' ]] || fail "licenses (file order, not sorted): $meta"

# glibc>=2.31 -> name stripped to "glibc", classified via the fake pacman
# as repo "core" (not the "aur" default).
glibc_entry="$(jq -c '.dependencies[] | select(.name == "glibc")' <<<"$meta")"
[[ "$(jq -r '.repo' <<<"$glibc_entry")" == "core" ]] || fail "glibc should classify as repo=core: $glibc_entry"
[[ "$(jq -r '.type' <<<"$glibc_entry")" == "depends" ]] || fail "glibc type: $glibc_entry"

# some-aur-only-dep -> not found via the fake pacman -> defaults to "aur".
aur_entry="$(jq -c '.dependencies[] | select(.name == "some-aur-only-dep")' <<<"$meta")"
[[ "$(jq -r '.repo' <<<"$aur_entry")" == "aur" ]] || fail "some-aur-only-dep should default to repo=aur: $aur_entry"

# optdepend "name: description" splitting.
opt_entry="$(jq -c '.dependencies[] | select(.name == "foo-tool")' <<<"$meta")"
[[ "$(jq -r '.type' <<<"$opt_entry")" == "optdepends" ]] || fail "foo-tool type: $opt_entry"
[[ "$(jq -r '.description' <<<"$opt_entry")" == "needed for the bar feature" ]] || fail "foo-tool description: $opt_entry"

# makedepend with no version constraint or description.
make_entry="$(jq -c '.dependencies[] | select(.name == "cmake")' <<<"$meta")"
[[ "$(jq -r '.type' <<<"$make_entry")" == "makedepends" ]] || fail "cmake type: $make_entry"
[[ "$(jq 'has("description")' <<<"$make_entry")" == "false" ]] || fail "cmake should have no description key: $make_entry"

[[ "$(jq -r '.dependencies | length' <<<"$meta")" == "4" ]] || fail "expected exactly 4 classified dependencies: $meta"

# --- regression guard: jq must actually be installed by this script
# before its own logic pipes through it. A real CI run caught this once
# already — the file_list.json/build_meta.json generation above was
# rewritten from python3 heredocs to bash|awk|jq, but the script's own
# `pacman -Sy --needed ...` line was never updated to install jq, so it
# worked in every local test (this machine already has jq) and failed
# outright the first time it ran in the real, bare archlinux:base-devel
# container with "jq: command not found". The tests above only exercise
# the tail of build.sh (sed-extracted, past the install line) so they
# can't catch this class of gap themselves — this checks the actual
# install line statically instead. ---
build_sh="$repo_root/backends/archlinux/build.sh"
grep -qE '\| ?jq\b|jq -' "$build_sh" || fail "build.sh no longer appears to use jq — if that's deliberate, this guard can go too"
install_line="$(grep -E '^\s*retry pacman -Sy .*--needed' "$build_sh")"
[[ -n "$install_line" ]] || fail "couldn't find build.sh's pacman -Sy --needed install line at all"
echo "$install_line" | grep -qw jq || fail "build.sh uses jq but its own 'pacman -Sy --needed' line doesn't install it: $install_line"

echo "backends/archlinux/build.sh file_list/build_meta tests passed"
