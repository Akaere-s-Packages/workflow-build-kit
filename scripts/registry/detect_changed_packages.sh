#!/usr/bin/env bash
set -euo pipefail

# Prints a JSON array of {"distro","type","name","path"} for Registry
# packages. Must be run from inside a checkout of the Registry repo.
#
# Layout: <distro>/<type>/<name>/<name>.toml (e.g. archlinux/aur/asusctl/asusctl.toml).
# Not distro-specific itself — this is pure path/git-diff bookkeeping over
# the Registry layout, same for every distro.
#
# Two modes:
#   detect_changed_packages.sh <base-ref> <head-ref>   only what changed
#                                                       between two refs
#                                                       (needs fetch-depth: 0)
#   detect_changed_packages.sh --all                   every package in the
#                                                       registry, regardless
#                                                       of git history — for
#                                                       a manual full rebuild
#   detect_changed_packages.sh --names <json-file>     packages named in a
#                                                       JSON string array

# Transforms a newline-separated list of "<distro>/<type>/<name>/<file>"
# paths (read from stdin) into the {"distro","type","name","path"} JSON
# array, dropping anything that isn't exactly 4 path segments or whose
# filename doesn't match its directory name.
to_packages_json() {
  jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(split("/"))
    | map(select(length == 4 and .[3] == (.[2] + ".toml")))
    | map({distro: .[0], type: .[1], name: .[2], path: (. | join("/"))})
  '
}

if [[ "${1:-}" == "--all" || "${1:-}" == "--names" ]]; then
  mode="$1"
  names_path="${2:-}"

  if [[ "$mode" == "--names" ]]; then
    [[ -f "$names_path" ]] || { echo "error: cannot read package names file '$names_path'" >&2; exit 1; }
    if ! jq -e 'type == "array" and all(type == "string")' "$names_path" >/dev/null 2>&1; then
      echo "error: invalid package names JSON in '$names_path' (must be a JSON array of strings)" >&2
      exit 1
    fi
  fi

  toml_paths=()
  shopt -s nullglob
  for f in */*/*/*.toml; do toml_paths+=("$f"); done
  shopt -u nullglob
  # Explicit C-locale sort (not relying on the shell's own glob order)
  # to match Python's plain ordinal string sort exactly.
  # A plain `sort` on the full path string is WRONG here: "-" (0x2D)
  # sorts before "/" (0x2F), so a flat-string sort would put
  # ".../samsung-unified-driver-common/..." ahead of the plain
  # ".../samsung-unified-driver/..." entry — a mismatch against Python's
  # pathlib, which compares paths by PARTS (a segment tuple), not as one
  # flat string. Swap "/" for a byte that sorts below any real filename
  # character first, so every segment boundary compares as "less than"
  # content within a segment, matching that component-wise order exactly.
  mapfile -t toml_paths < <(printf '%s\n' "${toml_paths[@]:-}" | tr '/' '\001' | LC_ALL=C sort | tr '\001' '/')

  packages_json="$(printf '%s\n' "${toml_paths[@]:-}" | to_packages_json)"

  if [[ "$mode" == "--names" ]]; then
    packages_json="$(jq -c --slurpfile names "$names_path" 'map(select(.name as $n | $names[0] | index($n)))' <<<"$packages_json")"
  fi

  echo "$packages_json"
  exit 0
fi

base_ref="${1:?base ref required (or pass --all to list every package)}"
head_ref="${2:?head ref required}"

# --diff-filter=d excludes deletions: a removed toml has nothing to build
# (resolve_build_order.sh would otherwise treat its now-vanished name as an
# unresolvable "unknown package" and hard-fail the whole run). Cleaning up
# a removed package's published files is handled separately, by the
# publish job reconciling the current Registry tree against the repo db —
# see backends/*/repo_lib.sh's prune_removed_packages.
changed="$(git diff --name-only --diff-filter=d "$base_ref" "$head_ref" -- '*/*/*/*.toml' || true)"

if [[ -z "$changed" ]]; then
  echo '[]'
  exit 0
fi

printf '%s\n' "$changed" | to_packages_json
