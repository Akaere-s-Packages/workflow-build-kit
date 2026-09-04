#!/usr/bin/env bash
set -euo pipefail

# Regenerate the package table in Registry/README.md between the
# PACKAGE_TABLE:START/END markers, leaving the rest of the file untouched.
# Distro-agnostic — the table columns (name/distro/source/version/
# autoupdate/last-updated/details link) are generic across every backend.
#
# README.md must already contain both marker lines once, by hand, before
# the first run — this script only ever replaces what's between them.
#
# Usage:
#   update_readme.sh --registry-root <Registry checkout>
#                     [--website-data-dir <WebSite-Kit checkout>/src/_data]
#                     [--pages-domain packages.pysio.online]

START="<!-- PACKAGE_TABLE:START -->"
END="<!-- PACKAGE_TABLE:END -->"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../lib/toml.sh"

registry_root="" website_data_dir="" pages_domain=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    --website-data-dir) website_data_dir="$2"; shift 2 ;;
    --pages-domain) pages_domain="$2"; shift 2 ;;
    *) echo "update_readme.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"

readme_path="$registry_root/README.md"
if [[ ! -f "$readme_path" ]] || ! grep -qF "$START" "$readme_path" || ! grep -qF "$END" "$readme_path"; then
  echo "::error::README.md must already contain a $START / $END marker pair before this script can run; add them once by hand first." >&2
  exit 1
fi

rows_file="$(mktemp)"
trap 'rm -f "$rows_file"' EXIT

toml_paths=()
shopt -s nullglob
for f in "$registry_root"/*/*/*/*.toml; do toml_paths+=("$f"); done
shopt -u nullglob
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

row_count=0
for toml_path in "${toml_paths[@]:-}"; do
  [[ -z "$toml_path" ]] && continue
  rel="${toml_path#"$registry_root"/}"
  IFS='/' read -r distro source_type dirname filename <<<"$rel"
  [[ "$filename" == "${dirname}.toml" ]] || continue

  fields_json="$(toml_to_json "$toml_path")"
  name="$(jq -r '.name' <<<"$fields_json")"
  version="$(jq -r '.version' <<<"$fields_json")"
  autoupdate="no"
  [[ "$(jq -r '.autoupdate // false' <<<"$fields_json")" == "true" ]] && autoupdate="yes"

  last_updated="-"
  if [[ -n "$website_data_dir" && -f "$website_data_dir/packageDetails/$name.json" ]]; then
    lu="$(jq -r '.last_updated // empty' "$website_data_dir/packageDetails/$name.json" 2>/dev/null || true)"
    [[ -n "$lu" ]] && last_updated="${lu:0:10}"
  fi

  base=""
  [[ -n "$pages_domain" ]] && base="https://$pages_domain"
  link="${base}/packages/${name}/"

  echo "| $name | $distro | $source_type | $version | $autoupdate | $last_updated | [details]($link) |" >> "$rows_file"
  row_count=$((row_count + 1))
done

table_md="| Package | Distro | Source | Version | Autoupdate | Last Updated | Details |"$'\n'"|---|---|---|---|---|---|---|"
[[ -s "$rows_file" ]] && table_md+=$'\n'"$(cat "$rows_file")"

# Trailing-newline-preserving read: a plain `$(cat file)` unconditionally
# strips ALL trailing newlines, which would silently change whatever
# comes after the END marker in the real file. Appending then stripping a
# sentinel character keeps them exactly as they were.
old_text="$(cat "$readme_path"; printf x)"
old_text="${old_text%x}"

before="${old_text%%"$START"*}"
rest="${old_text#*"$START"}"
after="${rest#*"$END"}"
new_text="${before}${START}"$'\n'"${table_md}"$'\n'"${END}${after}"

if [[ "$new_text" == "$old_text" ]]; then
  echo "README.md package table already up to date"
  exit 0
fi

printf '%s' "$new_text" > "$readme_path"
echo "updated README.md package table ($row_count packages)"
