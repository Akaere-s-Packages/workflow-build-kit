#!/usr/bin/env bash
set -euo pipefail

# Expand a set of changed packages to everything that needs building
# alongside them, and lay the result out in dependency-ordered build
# layers. Was resolve_build_order.py + most of aur_graph.py's role in it.
# Distro-agnostic: groups Registry entries by their `distro` field and
# asks each one's own backends/<distro>/fetch-info.sh for dependency
# data, then hands the combined graph to tools/depgraph — never assumes
# AUR/pacman itself.
#
# Given the packages that literally changed in this push/PR (from
# detect_changed_packages.sh), this:
#   1. Fetches live dependency data for every package in the Registry (not
#      just the changed ones — a changed package might be a dependency
#      *of* something unchanged, and that something needs to be pulled in
#      too, e.g. bumping asusctl should also rebuild rog-control-center
#      since it hard-depends on asusctl).
#   2. Finds every package connected (via hard depends) to a changed
#      package, unions those into the full build set.
#   3. Lays the build set out into ordered layers ("waves") via
#      tools/depgraph: layer 0 has no unbuilt dependency within the set
#      and can build in parallel; each later layer depends only on
#      earlier ones.
#
# Usage:
#   resolve_build_order.sh --registry-root <path> --changed <json-file-or-'-'>
#                           [--max-layers 5]
#
# --changed points at a JSON file with the same shape
# detect_changed_packages.sh prints (an array of {"distro","type","name","path"});
# pass '-' to read that JSON from stdin instead.
#
# Prints a JSON array of layers, each layer itself an array of package
# objects: [[{...}, {...}], [{...}]]. Always padded to exactly
# --max-layers entries (with empty layers) so the calling workflow can
# index layers[0]/[1]/[2] unconditionally.
#
# Requires tools/depgraph/depgraph to already be built (`make -C
# tools/depgraph`).

DEFAULT_MAX_LAYERS=5

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
depgraph="$repo_root/tools/depgraph/depgraph"

registry_root="" changed_arg="" max_layers=$DEFAULT_MAX_LAYERS
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    --changed) changed_arg="$2"; shift 2 ;;
    --max-layers) max_layers="$2"; shift 2 ;;
    *) echo "resolve_build_order.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
: "${changed_arg:?--changed required}"
[[ -x "$depgraph" ]] || { echo "::error::$depgraph not found or not executable — run 'make -C tools/depgraph' first" >&2; exit 1; }

if [[ "$changed_arg" == "-" ]]; then
  changed_json="$(cat)"
else
  changed_json="$(cat "$changed_arg")"
fi

changed_names="$(jq -r '[.[].name] | unique | .[]' <<<"$changed_json")"

if [[ -z "$changed_names" ]]; then
  jq -cn --argjson n "$max_layers" '[range($n)] | map([])'
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

"$script_dir/load_registry.sh" --registry-root "$registry_root" > "$work_dir/entries.json"
registry_root_abs="$(cd "$registry_root" && pwd)"

known_names="$(jq -r '.[].name' "$work_dir/entries.json" | LC_ALL=C sort -u)"
unknown="$(comm -23 <(printf '%s\n' "$changed_names" | LC_ALL=C sort -u) <(printf '%s\n' "$known_names"))"
if [[ -n "$unknown" ]]; then
  echo "::error::changed package(s) not found in registry: $(printf '%s ' $unknown)" >&2
  exit 1
fi

# --- fetch dependency info, grouped by distro (each distro's own backend
# answers for its own packages only) ---
echo '{}' > "$work_dir/info.json"
distros="$(jq -r '[.[].distro] | unique | .[]' "$work_dir/entries.json")"
while IFS= read -r distro; do
  [[ -z "$distro" ]] && continue
  backend="$repo_root/backends/$distro/fetch-info.sh"
  if [[ ! -x "$backend" ]]; then
    echo "::warning::no fetch-info.sh backend for distro '$distro' (expected $backend), continuing with no dependency data for it" >&2
    continue
  fi
  jq -c --arg d "$distro" '[.[] | select(.distro == $d) | .name]' "$work_dir/entries.json" \
    | "$backend" > "$work_dir/distro_info.json"
  jq -cs '.[0] + .[1]' "$work_dir/info.json" "$work_dir/distro_info.json" > "$work_dir/info.json.new"
  mv "$work_dir/info.json.new" "$work_dir/info.json"
done <<<"$distros"
rm -f "$work_dir/distro_info.json"

# --- build the depgraph edge-list input: name<TAB>dep1,dep2,... restricted
# to tracked names (an AUR dependency we don't track as a Registry package
# is irrelevant to build ordering) ---
jq -r -s --slurpfile info_arr "$work_dir/info.json" '
  .[0] as $entries
  | ($info_arr[0]) as $info
  | ([$entries[].name]) as $tracked
  | $entries[] | .name as $n
  | (($info[$n].depends // []) | map(select(. as $d | $tracked | index($d))) | unique) as $deps
  | "\($n)\t\($deps | join(","))"
' "$work_dir/entries.json" > "$work_dir/graph.txt"

jq -r '.[].name' "$work_dir/entries.json" | LC_ALL=C sort -u > "$work_dir/all_names.txt"
printf '%s\n' "$changed_names" > "$work_dir/changed_names.txt"

# --- expand changed set to every package connected to it ---
"$depgraph" components --subset "$work_dir/all_names.txt" < "$work_dir/graph.txt" > "$work_dir/components.txt"

build_set_file="$work_dir/build_set.txt"
: > "$build_set_file"
while IFS= read -r component_line; do
  [[ -z "$component_line" ]] && continue
  read -ra component_names <<<"$component_line"
  if comm -12 <(printf '%s\n' "${component_names[@]}" | LC_ALL=C sort -u) <(LC_ALL=C sort -u "$work_dir/changed_names.txt") | grep -q .; then
    printf '%s\n' "${component_names[@]}" >> "$build_set_file"
  fi
done < "$work_dir/components.txt"
LC_ALL=C sort -u -o "$build_set_file" "$build_set_file"

# --- layer the build set ---
if ! "$depgraph" layers --subset "$build_set_file" --max-layers "$max_layers" < "$work_dir/graph.txt" > "$work_dir/layers.json" 2>"$work_dir/depgraph.err"; then
  echo "::error::$(cat "$work_dir/depgraph.err")" >&2
  exit 1
fi

# Map each layer's bare names back to the full {distro,type,name,path}
# shape detect_changed_packages.sh uses, path relative to registry-root,
# then pad to exactly --max-layers entries (with empty layers) so the
# calling workflow can index layers[0]/[1]/[2] unconditionally.
jq -c --argjson n "$max_layers" --arg root "$registry_root_abs/" -s '
  .[0] as $layers | .[1] as $entries
  | ($entries | map({(.name): {distro:.distro, type:.type, name:.name,
      path: (.toml_path | ltrimstr($root)) }}) | add) as $by_name
  | ($layers | map([.[] | $by_name[.]])) as $result
  | $result + ([range($n - ($result | length))] | map([]))
' <(cat "$work_dir/layers.json") <(jq -c '.' "$work_dir/entries.json")
