#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file $1"
}

assert_not_file() {
  [[ ! -e "$1" ]] || fail "did not expect path $1"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source_dir="$tmp/out"
staged_dir="$tmp/artifact"
original_name='noto-fonts-sc-2:20210430-2-any.pkg.tar.zst'
staged_name='noto-fonts-sc-2%3A20210430-2-any.pkg.tar.zst'
mkdir -p "$source_dir"
printf 'package' > "$source_dir/$original_name"
printf '{}' > "$source_dir/manifest.json"

"$repo_root/scripts/build/stage_artifact.sh" stage "$source_dir" "$staged_dir"

assert_file "$source_dir/$original_name"
assert_file "$staged_dir/$staged_name"
assert_not_file "$staged_dir/$original_name"
assert_file "$staged_dir/artifact-name-map.json"

actual_map="$(jq -cS . "$staged_dir/artifact-name-map.json")"
expected_map="$(jq -cnS --arg k "$staged_name" --arg v "$original_name" '{files: {($k): $v}}')"
[[ "$actual_map" == "$expected_map" ]] || fail "artifact-name-map.json: expected $expected_map, got $actual_map"

"$repo_root/scripts/build/stage_artifact.sh" restore "$staged_dir"

assert_file "$staged_dir/$original_name"
assert_not_file "$staged_dir/$staged_name"

# restore on a directory that was never staged (no map file) is a silent
# no-op, not an error — e.g. a package that failed to build and left an
# empty/partial artifact dir behind.
never_staged="$tmp/never-staged"
mkdir -p "$never_staged"
"$repo_root/scripts/build/stage_artifact.sh" restore "$never_staged"

echo "artifact staging tests passed"
