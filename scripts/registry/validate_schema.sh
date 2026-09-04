#!/usr/bin/env bash
set -uo pipefail

# Validate Registry package TOML files against the aur/ schema. Distro-
# agnostic — the schema fields checked here (name/version/autoupdate/
# enabled/pkgbase/aur_depends/notes) are the generic Registry schema (see
# Docs/02-registry-schema.md), not anything backend-specific.
#
# Meant to run as the first, secret-free step of pr-preview.yml so a
# malformed toml fails fast before any build is attempted.
#
# Usage: validate_schema.sh <toml-path> [<toml-path> ...]
# Paths are expected relative to the Registry repo root, shaped
# <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../lib/toml.sh"

# `printf '%s\n' "${arr[@]}"` on a truly EMPTY array still runs the format
# once with no argument to fill %s — i.e. prints one blank line, not zero
# lines. That blank line would make the caller's error-accumulator file
# look non-empty even when there were no real errors. Guard against it here
# once instead of at every call site.
print_array() {
  (( $# > 0 )) && printf '%s\n' "$@"
  return 0
}

# Prints zero or more error lines (no ::error:: prefix — main adds that)
# for one toml file.
validate_one() {
  local raw_path="$1"
  local -a errors=()

  IFS='/' read -ra parts <<<"$raw_path"
  if (( ${#parts[@]} != 4 )); then
    echo "${raw_path}: expected a path shaped <distro>/<type>/<name>/<name>.toml"
    return
  fi
  local dirname="${parts[2]}" filename="${parts[3]}"

  if [[ "$filename" != "${dirname}.toml" ]]; then
    errors+=("${raw_path}: file name must match its directory name (${dirname}.toml)")
  fi

  if [[ ! -f "$raw_path" ]]; then
    errors+=("${raw_path}: invalid TOML (file not found)")
    print_array "${errors[@]}"
    return
  fi

  local err_file fields_json
  err_file="$(mktemp)"
  if ! fields_json="$(toml_to_json "$raw_path" 2>"$err_file")"; then
    errors+=("${raw_path}: invalid TOML ($(cat "$err_file"))")
    rm -f "$err_file"
    print_array "${errors[@]}"
    return
  fi
  rm -f "$err_file"

  # toml.sh is a line-scanner for this project's known-flat schema, not a
  # real TOML parser — it never raises a syntax error, it just silently
  # recognizes zero fields in anything it can't make sense of. So input
  # that isn't TOML at all (vs. well-formed TOML that's simply missing
  # [PACKAGES]) is reported the same way, here, rather than as "invalid
  # TOML" — still a hard failure either way, just a less specific message
  # for that one case.
  if ! grep -qx '\[PACKAGES\]' "$raw_path"; then
    errors+=("${raw_path}: missing [PACKAGES] table")
    print_array "${errors[@]}"
    return
  fi

  local name_type name
  name_type="$(jq -r '.name | type' <<<"$fields_json")"
  name="$(jq -r '.name // empty' <<<"$fields_json")"
  if [[ "$name_type" != "string" || -z "$name" ]]; then
    errors+=("${raw_path}: 'name' must be a non-empty string")
  elif [[ "$name" != "$dirname" ]]; then
    errors+=("${raw_path}: 'name' ('${name}') must match the directory name ('${dirname}')")
  fi

  local version
  version="$(jq -r 'if (.version | type) == "string" then .version else empty end' <<<"$fields_json")"
  if [[ -z "$version" || "$version" != *-* ]]; then
    errors+=("${raw_path}: 'version' must be a string shaped pkgver-pkgrel")
  fi

  [[ "$(jq -r '.autoupdate | type' <<<"$fields_json")" == "boolean" ]] \
    || errors+=("${raw_path}: 'autoupdate' must be a bool")

  if jq -e 'has("enabled")' <<<"$fields_json" >/dev/null; then
    [[ "$(jq -r '.enabled | type' <<<"$fields_json")" == "boolean" ]] \
      || errors+=("${raw_path}: 'enabled' must be a bool")
  fi

  if jq -e 'has("pkgbase")' <<<"$fields_json" >/dev/null; then
    [[ "$(jq -r '.pkgbase | type' <<<"$fields_json")" == "string" ]] \
      || errors+=("${raw_path}: 'pkgbase' must be a string")
  fi

  if jq -e 'has("aur_depends")' <<<"$fields_json" >/dev/null; then
    jq -e '(.aur_depends | type) == "array" and (.aur_depends | all(type == "string"))' <<<"$fields_json" >/dev/null \
      || errors+=("${raw_path}: 'aur_depends' must be a list of strings")
  fi

  if jq -e 'has("notes")' <<<"$fields_json" >/dev/null; then
    [[ "$(jq -r '.notes | type' <<<"$fields_json")" == "string" ]] \
      || errors+=("${raw_path}: 'notes' must be a string")
  fi

  print_array "${errors[@]}"
}

if [[ $# -eq 0 ]]; then
  echo "usage: validate_schema.sh <toml-path> [...]" >&2
  exit 2
fi

all_errors="$(mktemp)"
for raw in "$@"; do
  validate_one "$raw" >> "$all_errors"
done

if [[ -s "$all_errors" ]]; then
  while IFS= read -r err; do
    [[ -z "$err" ]] && continue
    echo "::error::$err"
  done < "$all_errors"
  rm -f "$all_errors"
  exit 1
fi

rm -f "$all_errors"
echo "ok: $# package file(s) validated"
exit 0
