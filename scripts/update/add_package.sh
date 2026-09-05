#!/usr/bin/env bash
set -uo pipefail

# Quick-add pipeline: given one upstream package name, resolves its full
# hard-dependency closure that isn't already available through the
# distro's own package manager (via backends/<distro>/fetch-info.sh +
# classify-dep.sh), generates a Registry TOML entry for every package in
# that closure that isn't already tracked, and opens a single PR
# introducing all of them at once — dependencies committed before
# dependents, same ordering convention scripts/update/check_updates.sh
# uses for version-bump PRs. Distro-agnostic: never assumes AUR/pacman
# itself, only that the target backend implements fetch-info.sh and the
# new classify-dep.sh contract entry (see backends/README.md).
#
# Must run inside a checkout of the Registry repo, on branch "main", with
# git user.name/user.email already configured and GH_TOKEN in the
# environment (used by both `git push` over https and `gh pr create`).
#
# Usage:
#   add_package.sh --registry-root <path> --package <name>
#                   [--distro archlinux] [--type aur]
#
# Requires tools/depgraph/depgraph to already be built (`make -C
# tools/depgraph`).

BASE_BRANCH="main"
MAX_CLOSURE_SIZE=50

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
depgraph="$repo_root/tools/depgraph/depgraph"
source "$repo_root/scripts/lib/run.sh"

registry_root="" package="" distro="archlinux" source_type="aur"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --distro) distro="$2"; shift 2 ;;
    --type) source_type="$2"; shift 2 ;;
    *) echo "add_package.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
: "${package:?--package required}"
[[ -x "$depgraph" ]] || { echo "::error::$depgraph not found or not executable — run 'make -C tools/depgraph' first" >&2; exit 1; }
registry_root="$(cd "$registry_root" && pwd)"

fetch_info_backend="$repo_root/backends/$distro/fetch-info.sh"
classify_backend="$repo_root/backends/$distro/classify-dep.sh"
index_url_backend="$repo_root/backends/$distro/index-url.sh"
[[ -x "$fetch_info_backend" ]] || { echo "::error::no fetch-info.sh backend for distro '$distro'" >&2; exit 1; }
[[ -x "$classify_backend" ]] || { echo "::error::no classify-dep.sh backend for distro '$distro'" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

"$script_dir/../registry/load_registry.sh" --registry-root "$registry_root" > "$work_dir/entries.json"
tracked_names="$(jq -r '.[].name' "$work_dir/entries.json" | LC_ALL=C sort -u)"

is_tracked() {
  grep -qxF "$1" <<<"$tracked_names"
}

# --- resolve the closure: BFS from $package, pulling in every hard
# dependency that classify-dep.sh calls "aur" and isn't already tracked.
#
# Batched by WAVE (BFS level), not one package at a time: fetch-info.sh
# and classify-dep.sh both accept a whole array of names per call, and
# fetch-info.sh in particular means a real network round-trip to AUR RPC
# per invocation. A naive one-call-per-package loop turns a closure of,
# say, 15 packages into 15 sequential AUR RPC requests — slower, and AUR
# RPC does rate-limit. Batching everything at the same depth into one
# call each cuts that to one round-trip per LEVEL of the dependency tree
# instead of one per package, which is what actually matters for a wide
# closure (many siblings depending on the same handful of things) even
# though it doesn't shorten a pathologically deep, narrow chain. ---
echo '{}' > "$work_dir/resolved.json"     # name -> {version, aur_depends: [...]}
: > "$work_dir/graph.txt"                 # depgraph input: name<TAB>dep1,dep2,...
: > "$work_dir/processed.txt"             # every name ever seen, tracked or not — never re-fetched
already_tracked_root=false
is_tracked "$package" && already_tracked_root=true

wave=("$package")
while (( ${#wave[@]} > 0 )); do
  # De-dup this wave against names already handled in an earlier wave
  # (or earlier in this same wave — a diamond dependency can list the
  # same name twice), and drop anything already tracked.
  to_process=()
  for name in "${wave[@]}"; do
    grep -qxF "$name" "$work_dir/processed.txt" 2>/dev/null && continue
    printf '%s\n' "$name" >> "$work_dir/processed.txt"
    is_tracked "$name" && continue
    to_process+=("$name")
  done
  if (( ${#to_process[@]} == 0 )); then
    wave=()
    continue
  fi

  resolved_so_far="$(jq 'length' "$work_dir/resolved.json")"
  if (( resolved_so_far + ${#to_process[@]} > MAX_CLOSURE_SIZE )); then
    echo "::error::dependency closure for '$package' exceeded $MAX_CLOSURE_SIZE packages — aborting, this smells like a misclassification loop rather than a real chain" >&2
    exit 1
  fi

  printf '%s\n' "${to_process[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))' > "$work_dir/wave_names.json"
  "$fetch_info_backend" < "$work_dir/wave_names.json" > "$work_dir/wave_info.json"

  missing=()
  for name in "${to_process[@]}"; do
    jq -e --arg n "$name" 'has($n)' "$work_dir/wave_info.json" >/dev/null || missing+=("$name")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "::error::not found via backends/$distro/fetch-info.sh (neither already tracked nor resolvable upstream): ${missing[*]}" >&2
    exit 1
  fi

  jq -c '[.[].depends[]?] | unique' "$work_dir/wave_info.json" > "$work_dir/wave_deps.json"
  echo '{}' > "$work_dir/wave_classified.json"
  if [[ "$(jq 'length' "$work_dir/wave_deps.json")" -gt 0 ]]; then
    "$classify_backend" < "$work_dir/wave_deps.json" > "$work_dir/wave_classified.json"
  fi

  next_wave=()
  for name in "${to_process[@]}"; do
    version="$(jq -r --arg n "$name" '.[$n].version' "$work_dir/wave_info.json")"
    # fetch-info.sh reports the real AUR PackageBase (falls back to $name
    # if a backend doesn't supply one at all — the field is new; an older
    # or future non-AUR backend might genuinely omit it). This matters:
    # a split PKGBUILD's non-base pkgname (e.g. rog-control-center, built
    # from asusctl's PKGBUILD) has its OWN name's AUR git namespace, but
    # that namespace is an empty placeholder — the real content lives
    # under the pkgbase's repo, which is what build.sh actually clones.
    # Silently defaulting pkgbase to name here (the previous behavior)
    # produced a TOML that looked fine but broke every build with a
    # useless "cloned an empty repository" / "PKGBUILD does not exist"
    # failure — caught for real via ttf-ms-win11-auto-zh_cn (pkgbase
    # ttf-ms-win11-auto), a Microsoft-fonts split package.
    pkgbase="$(jq -r --arg n "$name" '.[$n].pkgbase // $n' "$work_dir/wave_info.json")"
    aur_deps="$(jq -c -s --arg n "$name" '
      (.[0][$n].depends // []) as $deps | (.[1]) as $c
      | [$deps[] | select($c[.] == "aur")] | unique | sort
    ' "$work_dir/wave_info.json" "$work_dir/wave_classified.json")"

    jq -c --arg n "$name" --arg version "$version" --arg pkgbase "$pkgbase" --argjson aur_depends "$aur_deps" \
      '. + {($n): {version: $version, pkgbase: $pkgbase, aur_depends: $aur_depends}}' "$work_dir/resolved.json" > "$work_dir/resolved.json.new"
    mv "$work_dir/resolved.json.new" "$work_dir/resolved.json"

    deps_csv="$(jq -r 'join(",")' <<<"$aur_deps")"
    echo -e "${name}\t${deps_csv}" >> "$work_dir/graph.txt"

    while IFS= read -r dep_name; do
      [[ -z "$dep_name" ]] && continue
      next_wave+=("$dep_name")
    done < <(jq -r '.[]' <<<"$aur_deps")
  done

  wave=("${next_wave[@]}")
done
rm -f "$work_dir/wave_names.json" "$work_dir/wave_info.json" "$work_dir/wave_deps.json" "$work_dir/wave_classified.json"

new_count="$(jq 'length' "$work_dir/resolved.json")"
if [[ "$new_count" -eq 0 ]]; then
  if [[ "$already_tracked_root" == true ]]; then
    echo "'$package' is already tracked in the Registry; nothing to add"
  else
    echo "'$package' and its full dependency closure are already tracked in the Registry; nothing to add"
  fi
  exit 0
fi

# --- order: dependencies first (same convention as check_updates.sh) ---
jq -r 'keys[]' "$work_dir/resolved.json" | LC_ALL=C sort -u > "$work_dir/all_new_names.txt"
ordered_str="$("$depgraph" toposort --subset "$work_dir/all_new_names.txt" < "$work_dir/graph.txt" | tr '\n' ' ')"
read -ra ordered <<<"$ordered_str"

branch="add/$(IFS=+; echo "${ordered[*]}")"

echo "resolved ${#ordered[@]} new package(s) for '$package': ${ordered[*]}"
echo "target branch: $branch"

if ! retry_run gh pr list --head "$branch" --state open --json number,url; then
  echo "::warning::couldn't check for an existing PR on $branch, proceeding anyway" >&2
  existing_pr_url=""
else
  existing_pr_url="$(jq -r '.[0].url // empty' <<<"${run_stdout:-[]}")"
fi
if [[ -n "$existing_pr_url" ]]; then
  echo "branch $branch already has an open PR, leaving it alone: $existing_pr_url"
  exit 0
fi

run git checkout "$BASE_BRANCH"
run git branch -D "$branch"
if ! run git checkout -b "$branch"; then
  echo "::error::failed to create branch $branch" >&2
  exit 1
fi

pr_body="Opened automatically by an add-package run for \`$package\`."$'\n'
if (( ${#ordered[@]} > 1 )); then
  pr_body+="Includes ${#ordered[@]} packages: \`$package\` itself plus its AUR-only dependency closure."$'\n'
fi
pr_body+=$'\n'

failed=false
for name in "${ordered[@]}"; do
  version="$(jq -r --arg n "$name" '.[$n].version' "$work_dir/resolved.json")"
  pkgbase="$(jq -r --arg n "$name" '.[$n].pkgbase' "$work_dir/resolved.json")"
  aur_depends_json="$(jq -c --arg n "$name" '.[$n].aur_depends' "$work_dir/resolved.json")"

  pkg_dir="$registry_root/$distro/$source_type/$name"
  toml_path="$pkg_dir/$name.toml"
  if [[ -e "$toml_path" ]]; then
    echo "::error::refusing to overwrite existing file: $toml_path" >&2
    failed=true
    break
  fi
  mkdir -p "$pkg_dir"

  {
    echo "[PACKAGES]"
    echo "name = \"$name\""
    # Only written when it actually differs from name (matching every
    # existing hand-authored split-package TOML, e.g. rog-control-center's
    # pkgbase = "asusctl") — the common case stays a 4-line file.
    [[ "$pkgbase" != "$name" ]] && echo "pkgbase = \"$pkgbase\""
    echo "version = \"$version\""
    echo "autoupdate = true"
    if [[ "$(jq 'length' <<<"$aur_depends_json")" -gt 0 ]]; then
      echo "aur_depends = $(jq -c '.' <<<"$aur_depends_json")"
    fi
  } > "$toml_path"

  subject="$name: add $version"
  run git add "$toml_path"
  if ! run git commit -m "$subject"; then
    echo "::error::failed to prepare PR for $branch: git commit failed for $name" >&2
    failed=true
    break
  fi

  index_url=""
  [[ -x "$index_url_backend" ]] && index_url="$("$index_url_backend" "$name" 2>/dev/null || true)"
  root_marker=""
  [[ "$name" == "$package" ]] && root_marker=" (requested package)"
  if [[ -n "$index_url" ]]; then
    pr_body+="- \`$subject\`$root_marker — $index_url"$'\n'
  else
    pr_body+="- \`$subject\`$root_marker"$'\n'
  fi
done

if [[ "$failed" != true ]] && ! retry_run git push --force origin "$branch"; then
  failed=true
fi

if [[ "$failed" != true ]]; then
  title="add $package"
  extra_count=$(( ${#ordered[@]} - 1 ))
  if (( extra_count > 0 )); then
    noun="dependency package"; (( extra_count != 1 )) && noun="dependency packages"
    title="add $package (+$extra_count $noun)"
  fi
  if retry_run gh pr create --title "$title" --body "$pr_body" --head "$branch" --base "$BASE_BRANCH"; then
    printf '%s\n' "$run_stdout"
  else
    failed=true
  fi
fi

if [[ "$failed" == true ]]; then
  echo "::error::failed to open the add-package PR for $branch" >&2
fi

run git checkout "$BASE_BRANCH"
run git branch -D "$branch"

[[ "$failed" == true ]] && exit 1
exit 0
