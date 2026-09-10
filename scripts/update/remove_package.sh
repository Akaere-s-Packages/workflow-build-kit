#!/usr/bin/env bash
set -uo pipefail

# Removal counterpart to add_package.sh: given one or more package names
# already tracked in the Registry, deletes their
# <distro>/<type>/<name>/ directories and opens a single PR dropping
# them — dependents committed before their dependencies (the exact
# reverse of the add/bump ordering, since a removal unwinds the same
# graph from the other end).
#
# Refuses outright if any package still tracked in the Registry hard-
# depends on something being removed: dropping a package another one
# chain-builds against (`aur_depends`/build.sh's `extra-deps`) turns
# that dependent's next build into a failure, and a broken build is a
# much worse outcome than a removal that didn't happen. That's why this
# takes a LIST of packages rather than a single name like add_package.sh
# does: a package plus the dependencies that only ever existed to
# support it is one removal, not N sequential ones — listing the whole
# group in one run makes the check pass legitimately (dependents inside
# the removal set don't count) and lands as one atomic PR, instead of
# needing one PR per package with a broken intermediate state on main
# between each merge.
#
# Both dependency sources are consulted, because neither alone is
# enough: the Registry's own recorded `aur_depends` is authoritative for
# how a package is CHAIN-BUILT but is only written when add_package.sh
# generated the entry (most hand-authored TOMLs in the real Registry
# don't have the field at all), while backends/<distro>/fetch-info.sh
# reports what upstream currently declares for every tracked package,
# which is what resolve_build_order.sh already builds real build waves
# from. A dependency recorded in either place blocks the removal.
#
# There is deliberately no --force escape hatch. The legitimate "I know
# this dependent is going too" case is served by naming both packages in
# one run; anything past that is a hand-written PR deleting the file,
# which is a fine thing to do with human eyes on it and not something
# this should make one dropdown away.
#
# Nothing here touches the published pacman repository: merging the PR
# is what does that. build-publish.yml counts deleted manifests
# (`removed-count`) and its publish job repo-removes them from the
# shared repo DB and deletes their files from R2, then regenerates the
# README table and website data. clean.yml is the same reconciliation on
# demand, for drift left behind some other way.
#
# Must run inside a checkout of the Registry repo, on branch "main", with
# git user.name/user.email already configured and GH_TOKEN in the
# environment (used by both `git push` over https and `gh pr create`).
#
# Usage:
#   remove_package.sh --registry-root <path> --package <name>[,<name>...]
#                      [--package <name> ...]
#
# Requires tools/depgraph/depgraph to already be built (`make -C
# tools/depgraph`).

BASE_BRANCH="main"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
depgraph="$repo_root/tools/depgraph/depgraph"
source "$repo_root/scripts/lib/run.sh"
source "$repo_root/scripts/lib/toml.sh"

registry_root=""
requested=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    --package)
      # One flag can carry a whole list: the workflow_dispatch form is a
      # single free-text box, and "remove these three" typed with commas
      # or spaces is the natural thing for a human to write there.
      IFS=$', \t\n' read -ra _names <<<"$2"
      for _n in "${_names[@]}"; do
        [[ -n "$_n" ]] && requested+=("$_n")
      done
      shift 2 ;;
    *) echo "remove_package.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
(( ${#requested[@]} > 0 )) || { echo "remove_package.sh: --package required" >&2; exit 2; }
[[ -x "$depgraph" ]] || { echo "::error::$depgraph not found or not executable — run 'make -C tools/depgraph' first" >&2; exit 1; }
registry_root="$(cd "$registry_root" && pwd)"

# join_by <sep> <items...>: joins with an arbitrary (possibly multi-char)
# separator. Not `IFS=...; "${arr[*]}"` — that only ever uses IFS's FIRST
# character, which silently drops the space in ", ".
join_by() {
  local sep="$1"; shift
  local out="" item
  for item in "$@"; do
    [[ -n "$out" ]] && out+="$sep"
    out+="$item"
  done
  printf '%s' "$out"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

"$script_dir/../registry/load_registry.sh" --registry-root "$registry_root" > "$work_dir/entries.json"

# --- resolve requested names against what's actually tracked ---
targets=()   # de-duplicated, tracked-only, in the order given
untracked=()
for name in "${requested[@]}"; do
  printf '%s\n' "${targets[@]:-}" | grep -qxF "$name" && continue
  printf '%s\n' "${untracked[@]:-}" | grep -qxF "$name" && continue
  if jq -e --arg n "$name" 'any(.[]; .name == $n)' "$work_dir/entries.json" >/dev/null; then
    targets+=("$name")
  else
    untracked+=("$name")
  fi
done

if (( ${#untracked[@]} > 0 )); then
  # Not an error: "remove X" when X isn't there has already achieved what
  # it asked for. Worth saying out loud though — a typo'd name looks
  # exactly like this, and silently removing the other 2 of 3 packages
  # someone listed would be a nasty surprise.
  echo "::warning::not tracked in the Registry, nothing to remove for: ${untracked[*]}" >&2
fi
if (( ${#targets[@]} == 0 )); then
  echo "none of the requested package(s) are tracked in the Registry; nothing to remove"
  exit 0
fi

printf '%s\n' "${targets[@]}" | LC_ALL=C sort -u > "$work_dir/targets.txt"
jq -R -s -c 'split("\n") | map(select(length > 0))' "$work_dir/targets.txt" > "$work_dir/targets.json"

# --- dependency data for every tracked package, grouped by distro (each
# distro's own backend answers for its own packages only) — same shape
# resolve_build_order.sh builds its real build waves from. ---
echo '{}' > "$work_dir/info.json"
distros="$(jq -r '[.[].distro] | unique | .[]' "$work_dir/entries.json")"
while IFS= read -r distro; do
  [[ -z "$distro" ]] && continue
  backend="$repo_root/backends/$distro/fetch-info.sh"
  jq -c --arg d "$distro" '[.[] | select(.distro == $d) | .name]' "$work_dir/entries.json" > "$work_dir/distro_names.json"
  if [[ ! -x "$backend" ]]; then
    echo "::error::no fetch-info.sh backend for distro '$distro' (expected $backend) — can't verify what still depends on the package(s) being removed" >&2
    exit 1
  fi
  "$backend" < "$work_dir/distro_names.json" > "$work_dir/distro_info.json"
  # fetch-info.sh degrades to {} rather than failing when its upstream is
  # unreachable (see backends/README.md) — fine for "nothing new to
  # compare against", NOT fine here: silently treating "we couldn't ask"
  # as "nothing depends on it" is exactly how this would delete a package
  # three others chain-build against.
  if [[ "$(jq 'length' "$work_dir/distro_info.json")" -eq 0 ]] \
     && [[ "$(jq 'length' "$work_dir/distro_names.json")" -gt 0 ]]; then
    echo "::error::backends/$distro/fetch-info.sh returned no data for any tracked package — refusing to remove anything without being able to check reverse dependencies. Retry once upstream is reachable again." >&2
    exit 1
  fi
  jq -cs '.[0] + .[1]' "$work_dir/info.json" "$work_dir/distro_info.json" > "$work_dir/info.json.new"
  mv "$work_dir/info.json.new" "$work_dir/info.json"
done <<<"$distros"
rm -f "$work_dir/distro_names.json" "$work_dir/distro_info.json"

# --- what the Registry itself records: `aur_depends` isn't part of
# load_registry.sh's output shape (it's not one of the generic fields
# every consumer needs), so read it per manifest here. Local file reads,
# no network. ---
: > "$work_dir/recorded.tsv"
while IFS=$'\t' read -r name toml_path; do
  printf '%s\t%s\n' "$name" "$(toml_get_list "$toml_path" aur_depends)" >> "$work_dir/recorded.tsv"
done < <(jq -r '.[] | "\(.name)\t\(.toml_path)"' "$work_dir/entries.json")
jq -R -s -c '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  | map({key: .[0], value: ((.[1] // "") | split(" ") | map(select(length > 0)))})
  | from_entries
' "$work_dir/recorded.tsv" > "$work_dir/recorded.json"

# name -> its hard dependencies, restricted to tracked names: upstream's
# current `depends` unioned with whatever the Registry recorded in
# `aur_depends` (see the header — neither source alone covers every
# tracked package).
jq -c --slurpfile info_arr "$work_dir/info.json" --slurpfile recorded_arr "$work_dir/recorded.json" '
  ($info_arr[0]) as $info
  | ($recorded_arr[0]) as $recorded
  | ([.[].name]) as $tracked
  | [ .[]
      | .name as $n
      | { key: $n,
          value: ((($info[$n].depends // []) + ($recorded[$n] // []))
                  | map(select(. as $d | $tracked | index($d)))
                  | unique) } ]
  | from_entries
' "$work_dir/entries.json" > "$work_dir/deps.json"

# --- refuse if anything still tracked depends on a removal target ---
jq -r --slurpfile targets_arr "$work_dir/targets.json" '
  ($targets_arr[0]) as $targets
  | to_entries
  | map(select(.key as $k | ($targets | index($k)) | not))
  | map(. as $e | ($e.value | map(select(. as $d | $targets | index($d)))) as $hits
        | select($hits | length > 0) | "\($e.key) -> \($hits | join(", "))")
  | .[]
' "$work_dir/deps.json" > "$work_dir/blockers.txt"

if [[ -s "$work_dir/blockers.txt" ]]; then
  echo "::error::refusing to remove $(join_by ", " "${targets[@]}") — these tracked packages still hard-depend on them:" >&2
  sed 's/^/::error::  /' "$work_dir/blockers.txt" >&2
  echo "::error::remove the dependent(s) in the same run (pass every name at once) if they're going too, or drop the dependency upstream first" >&2
  exit 1
fi

# --- tracked packages whose dependency data couldn't be established at
# all (upstream doesn't know the name AND the Registry records no
# aur_depends for it) weren't really cleared by the check above, they
# were just silent. Real case: rog-control-center is tracked, but AUR RPC
# returns nothing for that name — it's a pkgname produced by asusctl's
# split PKGBUILD and only the pkgbase is indexed — so no amount of
# querying will ever say what it depends on. Aborting on that would make
# the whole Registry permanently unremovable; saying nothing would
# overstate what was checked. So: warn, and put it in the PR body where
# the reviewer sees it. ---
jq -r --slurpfile targets_arr "$work_dir/targets.json" \
      --slurpfile info_arr "$work_dir/info.json" \
      --slurpfile recorded_arr "$work_dir/recorded.json" '
  ($targets_arr[0]) as $targets
  | ($info_arr[0]) as $info
  | ($recorded_arr[0]) as $recorded
  | [ .[].name
      | select(. as $n | ($targets | index($n)) | not)
      | select(. as $n | ($info | has($n)) | not)
      | select(. as $n | (($recorded[$n] // []) | length) == 0) ]
  | .[]
' "$work_dir/entries.json" > "$work_dir/unverified.txt"
if [[ -s "$work_dir/unverified.txt" ]]; then
  echo "::warning::no dependency data available for these tracked packages, so they were NOT checked for a dependency on what's being removed: $(tr '\n' ' ' < "$work_dir/unverified.txt")" >&2
fi

# --- order: dependents before dependencies (reverse of add/bump) ---
jq -r 'to_entries | .[] | "\(.key)\t\(.value | join(","))"' "$work_dir/deps.json" > "$work_dir/graph.txt"
ordered_str="$("$depgraph" toposort --subset "$work_dir/targets.txt" < "$work_dir/graph.txt" | tac | tr '\n' ' ')"
read -ra ordered <<<"$ordered_str"

branch="remove/$(IFS=+; echo "${ordered[*]}")"

echo "removing ${#ordered[@]} package(s): ${ordered[*]}"
echo "target branch: $branch"

# --- packages that only existed to support something being removed:
# reported, never removed automatically. "Nothing else depends on it
# anymore" is a strong hint and a weak proof — a package can be tracked
# on its own merits (it's the thing someone actually installs) and this
# can't tell that apart from a leftover chain-build dependency, so it
# goes in the PR body for a human to decide on. ---
jq -r --slurpfile targets_arr "$work_dir/targets.json" '
  ($targets_arr[0]) as $targets
  | . as $deps
  | ([$targets[] | ($deps[.] // [])[]] | unique) as $needed_by_removed
  | ([$deps | to_entries[]
      | select(.key as $k | ($targets | index($k)) | not)
      | .value[]] | unique) as $needed_by_survivors
  | $needed_by_removed
  | map(select(. as $d | ($targets | index($d)) | not))
  | map(select(. as $d | ($needed_by_survivors | index($d)) | not))
  | .[]
' "$work_dir/deps.json" > "$work_dir/orphans.txt"
if [[ -s "$work_dir/orphans.txt" ]]; then
  echo "note: nothing tracked will depend on these anymore: $(tr '\n' ' ' < "$work_dir/orphans.txt")"
fi

# --- one PR, same conservative stance as add_package.sh: a branch that
# already has an open PR is left completely alone rather than force-
# pushed over. This is human-triggered and possibly mid-review, not a
# daily job whose answer is expected to be recomputed. ---
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

pr_body="Opened automatically by a remove-package run for \`$(join_by '`, `' "${targets[@]}")\`."$'\n'
if (( ${#ordered[@]} > 1 )); then
  pr_body+="Dependents are dropped before their dependencies, the reverse of how they were added."$'\n'
fi
pr_body+=$'\n'

failed=false
for name in "${ordered[@]}"; do
  entry="$(jq -c --arg n "$name" 'map(select(.name == $n)) | .[0]' "$work_dir/entries.json")"
  version="$(jq -r '.version' <<<"$entry")"
  toml_path="$(jq -r '.toml_path' <<<"$entry")"
  pkg_dir="$(dirname "$toml_path")"

  # -r, not just the toml: the whole <name>/ directory is the package's
  # slot in the Registry layout, and leaving an empty (or worse,
  # half-emptied) one behind is drift nothing else knows how to clean up.
  if ! run git rm -r --quiet "$pkg_dir"; then
    echo "::error::failed to delete $pkg_dir" >&2
    failed=true
    break
  fi

  subject="$name: remove $version"
  if ! run git commit -m "$subject"; then
    echo "::error::failed to prepare PR for $branch: git commit failed for $name" >&2
    failed=true
    break
  fi
  pr_body+="- \`$subject\`"$'\n'
done

if [[ "$failed" != true && -s "$work_dir/unverified.txt" ]]; then
  pr_body+=$'\n'"Not checked (nothing upstream or in the Registry says what they depend on) — worth an eyeball before merging:"$'\n'
  while IFS= read -r unverified; do
    [[ -z "$unverified" ]] && continue
    pr_body+="- \`$unverified\`"$'\n'
  done < "$work_dir/unverified.txt"
fi

if [[ "$failed" != true && -s "$work_dir/orphans.txt" ]]; then
  pr_body+=$'\n'"Nothing tracked will hard-depend on these once this merges — worth checking whether they're still wanted on their own:"$'\n'
  while IFS= read -r orphan; do
    [[ -z "$orphan" ]] && continue
    pr_body+="- \`$orphan\`"$'\n'
  done < "$work_dir/orphans.txt"
fi

if [[ "$failed" != true ]]; then
  pr_body+=$'\n'"Merging this drops the package(s) from the published repository too: build-and-publish repo-removes them from the shared pacman DB, deletes their files from R2, and regenerates the README table and website data."$'\n'
fi

if [[ "$failed" != true ]] && ! retry_run git push --force origin "$branch"; then
  failed=true
fi

if [[ "$failed" != true ]]; then
  title="remove $(join_by ", " "${ordered[@]}")"
  if (( ${#ordered[@]} > 3 )); then
    title="remove ${ordered[0]} (+$(( ${#ordered[@]} - 1 )) more)"
  fi
  if retry_run gh pr create --title "$title" --body "$pr_body" --head "$branch" --base "$BASE_BRANCH"; then
    printf '%s\n' "$run_stdout"
  else
    failed=true
  fi
fi

if [[ "$failed" == true ]]; then
  echo "::error::failed to open the remove-package PR for $branch" >&2
fi

run git checkout "$BASE_BRANCH"
run git branch -D "$branch"

[[ "$failed" == true ]] && exit 1
exit 0
