# Shared TOML reader for Registry package files. Sourced, not run standalone.
#
# Registry's `[PACKAGES]` table (see Docs/02-registry-schema.md) is always
# flat — one `key = value` per line, single-line string/bool/string-array
# values, no nesting, no inline comments — confirmed against every real
# file in the Registry repo. That's simple enough for a small line-oriented
# reader; no general TOML library needed.
#
# Requires: jq (already a hard dependency everywhere else in this repo).

# toml_to_json <path>: prints the [PACKAGES] table as one JSON object.
# Lines outside [PACKAGES] (there shouldn't be any per the schema, but a
# stray second section must not leak into the result) are ignored.
toml_to_json() {
  local file="$1"
  [[ -f "$file" ]] || { echo "toml_to_json: no such file: $file" >&2; return 1; }

  local in_table=false
  local jq_args=() fields=()
  local line key raw

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" == "[PACKAGES]" ]]; then
      in_table=true
      continue
    fi
    if [[ "$line" =~ ^\[.*\]$ ]]; then
      in_table=false
      continue
    fi
    $in_table || continue

    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"

    if [[ "$raw" == "true" || "$raw" == "false" ]]; then
      jq_args+=(--argjson "$key" "$raw")
    elif [[ "$raw" =~ ^\[.*\]$ ]]; then
      local inner elems=() item json_arr
      inner="${raw#[}"; inner="${inner%]}"
      if [[ -n "${inner//[[:space:]]/}" ]]; then
        local IFS=','
        read -ra items <<<"$inner"
        unset IFS
        for item in "${items[@]}"; do
          item="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' <<<"$item")"
          elems+=("$item")
        done
        json_arr="$(printf '%s\n' "${elems[@]}" | jq -R . | jq -cs .)"
      else
        json_arr="[]"
      fi
      jq_args+=(--argjson "$key" "$json_arr")
    else
      local val="$raw"
      [[ "$val" =~ ^\".*\"$ ]] && { val="${val#\"}"; val="${val%\"}"; }
      jq_args+=(--arg "$key" "$val")
    fi
    fields+=("$key: \$$key")
  done < "$file"

  local program
  program="{ $(IFS=,; echo "${fields[*]:-}") }"
  jq -n "${jq_args[@]}" "$program"
}

# toml_get <path> <key>: prints one scalar field's raw value (the literal
# text "true"/"false" for a bool, or the string value). Absent key -> empty
# string. Do not use on an array field, use toml_get_list for that.
#
# Deliberately `if has($k) then ... else empty end`, NOT `.[$k] // empty`:
# jq's `//` treats JSON `false` as falsy too, so a legitimately-set
# `enabled = false` would otherwise print as empty — indistinguishable from
# the field being absent at all.
toml_get() {
  local file="$1" key="$2"
  toml_to_json "$file" | jq -r --arg k "$key" 'if has($k) then .[$k] else empty end'
}

# toml_get_list <path> <key>: prints a string-array field's elements
# space-separated (matching the old `' '.join(...)` call sites). Absent
# key -> empty string.
toml_get_list() {
  local file="$1" key="$2"
  toml_to_json "$file" | jq -r --arg k "$key" '(.[$k] // []) | join(" ")'
}
