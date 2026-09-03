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

python3 "$repo_root/scripts/build/stage_artifact.py" stage "$source_dir" "$staged_dir"

assert_file "$source_dir/$original_name"
assert_file "$staged_dir/$staged_name"
assert_not_file "$staged_dir/$original_name"
assert_file "$staged_dir/artifact-name-map.json"

python3 - "$staged_dir/artifact-name-map.json" "$staged_name" "$original_name" <<'PY'
import json
import sys

with open(sys.argv[1]) as mapping_file:
    mappings = json.load(mapping_file)

assert mappings == {"files": {sys.argv[2]: sys.argv[3]}}, mappings
PY

python3 "$repo_root/scripts/build/stage_artifact.py" restore "$staged_dir"

assert_file "$staged_dir/$original_name"
assert_not_file "$staged_dir/$staged_name"
echo "artifact staging tests passed"
