#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/lib/toml.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- minimal file: only the required fields ---
cat > "$tmp/minimal.toml" <<'EOF'
[PACKAGES]
name = "asusctl"
version = "6.4.0-1"
autoupdate = true
EOF
json="$(toml_to_json "$tmp/minimal.toml" | jq -cS .)"
[[ "$json" == '{"autoupdate":true,"name":"asusctl","version":"6.4.0-1"}' ]] || fail "minimal.toml: got $json"
[[ "$(toml_get "$tmp/minimal.toml" name)" == "asusctl" ]] || fail "toml_get name"
[[ "$(toml_get "$tmp/minimal.toml" autoupdate)" == "true" ]] || fail "toml_get autoupdate"
[[ -z "$(toml_get "$tmp/minimal.toml" pkgbase)" ]] || fail "toml_get on missing optional field should be empty"
[[ -z "$(toml_get_list "$tmp/minimal.toml" aur_depends)" ]] || fail "toml_get_list on missing array field should be empty"

# --- full file: every optional field, including a multi-element array ---
cat > "$tmp/full.toml" <<'EOF'
[PACKAGES]
name = "yubico-authenticator"
pkgbase = "yubico-authenticator"
version = "7.4.1-2"
autoupdate = true
enabled = false
aur_depends = ["python-zxing-cpp", "some-other-dep"]
notes = "needs manual review"
EOF
[[ "$(toml_get "$tmp/full.toml" pkgbase)" == "yubico-authenticator" ]] || fail "toml_get pkgbase"
[[ "$(toml_get "$tmp/full.toml" enabled)" == "false" ]] || fail "toml_get enabled (false)"
[[ "$(toml_get_list "$tmp/full.toml" aur_depends)" == "python-zxing-cpp some-other-dep" ]] || fail "toml_get_list aur_depends"
[[ "$(toml_get "$tmp/full.toml" notes)" == "needs manual review" ]] || fail "toml_get notes"

# --- empty array ---
cat > "$tmp/empty_array.toml" <<'EOF'
[PACKAGES]
name = "foo"
version = "1-1"
autoupdate = false
aur_depends = []
EOF
[[ -z "$(toml_get_list "$tmp/empty_array.toml" aur_depends)" ]] || fail "empty aur_depends should be empty"
json="$(toml_to_json "$tmp/empty_array.toml" | jq -c '.aur_depends')"
[[ "$json" == "[]" ]] || fail "empty aur_depends json array: got $json"

# --- differential check against every real Registry toml file (Python's
# tomllib as ground truth) — belt-and-suspenders beyond the synthetic cases
# above, since these are the actual files this parser has to handle in
# production. ---
registry_dir="$repo_root/../Registry"
if [[ -d "$registry_dir" ]] && command -v python3 >/dev/null; then
  shopt -s nullglob
  for f in "$registry_dir"/*/*/*/*.toml; do
    ours="$(toml_to_json "$f" | jq -cS .)"
    theirs="$(python3 -c "
import tomllib, json, sys
with open('$f', 'rb') as fh:
    d = tomllib.load(fh)['PACKAGES']
print(json.dumps(d, sort_keys=True, separators=(',', ':')))
")"
    [[ "$ours" == "$theirs" ]] || fail "differential mismatch on $f: bash=$ours python=$theirs"
  done
  shopt -u nullglob
else
  echo "note: skipping differential check against ../Registry (not found, or no python3)" >&2
fi

echo "toml.sh tests passed"
