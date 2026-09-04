#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/registry/validate_schema.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Runs "$script $@", leaving output in $out and its exit status in
# $status — a plain `out="$(cmd)"; status=$?` would trip `set -e` on the
# assignment itself the moment cmd exits nonzero, before status=$? ever
# runs (the same command-substitution/set -e trap this migration keeps
# running into elsewhere).
run_validate() {
  set +e
  out="$("$script" "$@" 2>&1)"
  status=$?
  set -e
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

mkdir -p archlinux/aur/good archlinux/aur/mismatch archlinux/aur/noversion archlinux/aur/badtypes archlinux/aur/nopkg shallow/deep
printf '%s\n' '[PACKAGES]' 'name = "good"' 'version = "1.0-1"' 'autoupdate = true' 'pkgbase = "good"' \
  'aur_depends = ["a", "b"]' 'notes = "fine"' > archlinux/aur/good/good.toml
printf '%s\n' '[PACKAGES]' 'name = "wrongname"' 'version = "1.0-1"' 'autoupdate = true' > archlinux/aur/mismatch/mismatch.toml
printf '%s\n' '[PACKAGES]' 'name = "noversion"' 'version = "1.0"' 'autoupdate = true' > archlinux/aur/noversion/noversion.toml
printf '%s\n' '[PACKAGES]' 'name = "badtypes"' 'version = "1.0-1"' 'autoupdate = "yes"' 'enabled = "no"' > archlinux/aur/badtypes/badtypes.toml
printf '%s\n' '[OTHER]' 'x = 1' > archlinux/aur/nopkg/nopkg.toml
printf '%s\n' '[PACKAGES]' 'name = "deep"' 'version = "1-1"' 'autoupdate = true' > shallow/deep/deep.toml

# --- a single valid file: exit 0, "ok" message ---
run_validate archlinux/aur/good/good.toml
[[ $status -eq 0 ]] || fail "valid file should exit 0"
[[ "$out" == "ok: 1 package file(s) validated" ]] || fail "unexpected ok message: $out"

# --- name/directory mismatch ---
run_validate archlinux/aur/mismatch/mismatch.toml
[[ $status -eq 1 ]] || fail "mismatch should exit 1"
[[ "$out" == *"'name' ('wrongname') must match the directory name ('mismatch')"* ]] || fail "unexpected: $out"

# --- version without a hyphen ---
run_validate archlinux/aur/noversion/noversion.toml
[[ "$out" == *"'version' must be a string shaped pkgver-pkgrel"* ]] || fail "unexpected: $out"

# --- wrong types for autoupdate/enabled ---
run_validate archlinux/aur/badtypes/badtypes.toml
[[ "$out" == *"'autoupdate' must be a bool"* ]] || fail "unexpected: $out"
[[ "$out" == *"'enabled' must be a bool"* ]] || fail "unexpected: $out"

# --- missing [PACKAGES] table ---
run_validate archlinux/aur/nopkg/nopkg.toml
[[ "$out" == *"missing [PACKAGES] table"* ]] || fail "unexpected: $out"

# --- wrong path depth ---
run_validate shallow/deep/deep.toml
[[ "$out" == *"expected a path shaped <distro>/<type>/<name>/<name>.toml"* ]] || fail "unexpected: $out"

# --- nonexistent file ---
run_validate archlinux/aur/ghost/ghost.toml
[[ "$out" == *"invalid TOML (file not found)"* ]] || fail "unexpected: $out"

# --- multiple files at once: every error surfaces, exit 1 ---
run_validate archlinux/aur/good/good.toml archlinux/aur/mismatch/mismatch.toml archlinux/aur/noversion/noversion.toml
[[ $status -eq 1 ]] || fail "batch with any bad file should exit 1"
[[ "$out" == *"mismatch"* ]] || fail "batch output missing mismatch error: $out"
[[ "$out" == *"noversion"* ]] || fail "batch output missing noversion error: $out"
[[ "$out" != *"good.toml:"* ]] || fail "the valid file should not produce any error line: $out"

# --- no arguments: usage message, exit 2 ---
run_validate
[[ $status -eq 2 ]] || fail "no-args should exit 2, got $status"

echo "validate_schema.sh tests passed"
