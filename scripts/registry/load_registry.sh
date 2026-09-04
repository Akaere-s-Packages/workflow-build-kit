#!/usr/bin/env bash
set -euo pipefail

# Loads every Registry package entry as JSON. Layout:
# <distro>/<type>/<name>/<name>.toml, e.g. archlinux/aur/asusctl/asusctl.toml.
# Distro-agnostic — reads only the generic Registry schema fields (see
# Docs/02-registry-schema.md), never anything backend-specific. Was
# aur_graph.py's load_registry() function.
#
# Usage: load_registry.sh --registry-root <path>
#
# Prints a JSON array of:
#   {distro,type,name,pkgbase,version,autoupdate,enabled,toml_path}
# toml_path is absolute, so callers can both re-derive the path relative to
# registry-root (for output shapes that want it) and read/edit the file
# directly without needing registry-root passed around separately.

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$lib_dir/toml.sh"

registry_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    *) echo "load_registry.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
registry_root="$(cd "$registry_root" && pwd)"

toml_paths=()
shopt -s nullglob
for f in "$registry_root"/*/*/*/*.toml; do toml_paths+=("$f"); done
shopt -u nullglob
# Explicit C-locale sort (not relying on the shell's own glob order) to
# match Python's plain ordinal string sort exactly.
# A plain `sort` on the full path string is WRONG here: comparing
# ".../samsung-unified-driver/..." against
# ".../samsung-unified-driver-common/..." byte-for-byte, "-" (0x2D) sorts
# BEFORE "/" (0x2F), so the flat string sort would put "-common" ahead of
# the plain "samsung-unified-driver" entry — a real mismatch against
# Python's pathlib, which compares paths by PARTS (a tuple of segments),
# not as one flat string, so the shorter segment always sorts first.
# Replacing "/" with a byte that sorts below any real filename character
# before sorting (then converting back) makes every segment boundary
# compare as "less than" any content within a segment, matching that
# component-wise ordering exactly.
mapfile -t toml_paths < <(printf '%s\n' "${toml_paths[@]:-}" | tr '/' '\001' | LC_ALL=C sort | tr '\001' '/')

entries="[]"
for toml_path in "${toml_paths[@]:-}"; do
  [[ -z "$toml_path" ]] && continue
  rel="${toml_path#"$registry_root"/}"
  IFS='/' read -r distro source_type dirname filename <<<"$rel"
  [[ "$filename" == "${dirname}.toml" ]] || continue

  fields_json="$(toml_to_json "$toml_path")"
  name="$(jq -r '.name' <<<"$fields_json")"
  pkgbase="$(jq -r '.pkgbase // empty' <<<"$fields_json")"
  [[ -z "$pkgbase" ]] && pkgbase="$name"
  version="$(jq -r '.version' <<<"$fields_json")"
  autoupdate="$(jq -r '.autoupdate // false' <<<"$fields_json")"
  # `enabled` defaults to true when absent — checked via has(), not `//
  # true`, since `//` would also silently override a real `enabled =
  # false` (jq's `//` treats JSON false as falsy too — see toml.sh's
  # toml_get for the same trap).
  enabled="$(jq -r 'if has("enabled") then .enabled else true end' <<<"$fields_json")"

  entry="$(jq -n \
    --arg distro "$distro" --arg type "$source_type" --arg name "$name" \
    --arg pkgbase "$pkgbase" --arg version "$version" \
    --argjson autoupdate "$autoupdate" --argjson enabled "$enabled" \
    --arg toml_path "$toml_path" \
    '{distro:$distro,type:$type,name:$name,pkgbase:$pkgbase,version:$version,
      autoupdate:$autoupdate,enabled:$enabled,toml_path:$toml_path}')"
  entries="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$entries")"
done

echo "$entries"
