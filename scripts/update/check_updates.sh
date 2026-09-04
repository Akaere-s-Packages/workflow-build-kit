#!/usr/bin/env bash
set -uo pipefail

# Find Registry packages with autoupdate=true that have a newer version
# upstream (via each candidate's own backends/<distro>/fetch-info.sh —
# this script itself never assumes AUR/pacman), group ones that
# hard-depend on each other into a single PR (one commit per package,
# dependencies committed first, following the AOSC packaging commit
# convention: "$pkgname: update to $pkgver"), and open one PR per group.
# Packages with no dependency relationship to any other pending update
# each get their own single-package PR.
#
# If a group's branch already has an open PR, this doesn't open a second
# one: it force-pushes the branch (rebuilt fresh from main, so it never
# accumulates stale commits) with the current target versions and updates
# the PR's title/body in place. If that branch is already at the exact
# versions being targeted (e.g. two runs in a row with nothing new
# upstream since the PR was opened), it's left untouched — no-op
# force-pushes and duplicate work are both avoided.
#
# Every PR this creates or updates is left as a plain open PR on a
# `bump/<name>[+<name>...]` branch — merging it is
# scripts/update/merge_queue.sh's job, not this script's: merge_queue.sh
# (run by merge-queue.yml, triggered after every pr-preview/
# build-and-publish run) independently discovers all open `bump/*` PRs,
# waits for each one's pr-preview build to actually pass, and merges them
# one at a time, never while this repo has any other Actions run in
# progress. The only remaining manual prerequisite is "Allow rebase
# merging" under Settings -> General -> Pull Requests — merge_queue.sh's
# own `gh pr merge --rebase` needs that merge strategy allowed.
#
# Must run inside a checkout of the Registry repo, on branch "main", with
# git user.name/user.email already configured and GH_TOKEN in the
# environment (used by both `git push` over https and `gh pr create`/
# `edit`). GH_TOKEN is read from the environment by git/gh themselves,
# never passed as a literal argument, so it's safe that every command run
# here (with its full stdout/stderr) is printed unconditionally for
# debugging (see scripts/lib/run.sh).
#
# Usage: check_updates.sh --registry-root <path to the checkout>
#
# Requires tools/depgraph/depgraph to already be built (`make -C
# tools/depgraph`).

BASE_BRANCH="main"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
depgraph="$repo_root/tools/depgraph/depgraph"
source "$repo_root/scripts/lib/run.sh"

registry_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    *) echo "check_updates.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
[[ -x "$depgraph" ]] || { echo "::error::$depgraph not found or not executable — run 'make -C tools/depgraph' first" >&2; exit 1; }
registry_root="$(cd "$registry_root" && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Sets $open_pr_number/$open_pr_title (both empty if there's no open PR
# for this branch).
find_open_pr() {
  local branch="$1"
  open_pr_number="" open_pr_title=""
  retry_run gh pr list --head "$branch" --state open --json number,title
  local stdout="${run_stdout:-}"
  [[ -z "$stdout" ]] && return 0
  open_pr_number="$(jq -r '.[0].number // empty' <<<"$stdout")"
  open_pr_title="$(jq -r '.[0].title // empty' <<<"$stdout")"
  return 0
}

# Sets $branch_version to the `version = "..."` currently on
# `origin/<branch>` for that file (empty if the branch/file doesn't
# exist). Requires `origin/<branch>` to already be fetched. A global, not
# an echoed return value — this calls run(), whose debug-visibility
# printing must reach the real log, not get captured by a command
# substitution wrapped around this function (the exact trap
# scripts/update/merge_queue.sh's find_ready_pr avoids the same way).
branch_file_version() {
  local branch="$1" rel_path="$2"
  branch_version=""
  run git show "origin/$branch:$rel_path" || return 0
  branch_version="$(grep -oP 'version\s*=\s*"\K[^"]+' <<<"$run_stdout" | head -1)"
}

# dirty.json field lookup: dirty_field <name> <field>
dirty_field() {
  jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // empty' "$work_dir/dirty.json"
}

# join_by <sep> <items...>: joins with an arbitrary (possibly multi-char)
# separator — NOT the `IFS=...; "${arr[*]}"` trick, which silently only
# uses IFS's FIRST character as the separator regardless of how many
# characters it's set to (harmless for the single-char "+" branch-name
# join below, but wrong for anything wider like ", ").
join_by() {
  local sep="$1"; shift
  local result="${1-}"; shift || true
  local item
  for item in "$@"; do
    result+="$sep$item"
  done
  printf '%s' "$result"
}

process_group() {
  local -a ordered=("$@")
  local branch="bump/$(IFS=+; echo "${ordered[*]}")"

  find_open_pr "$branch"

  if [[ -n "$open_pr_number" ]]; then
    retry_run git fetch origin "$branch"
    local already_current=true name
    for name in "${ordered[@]}"; do
      local rel_path new_version
      rel_path="$(dirty_field "$name" rel_path)"
      new_version="$(dirty_field "$name" new_version)"
      branch_file_version "$branch" "$rel_path"
      if [[ "$branch_version" != "$new_version" ]]; then
        already_current=false
        break
      fi
    done
    if [[ "$already_current" == true ]]; then
      echo "branch $branch (PR #$open_pr_number) is already at the latest versions, nothing to do"
      return 0
    fi
    echo "branch $branch (PR #$open_pr_number) exists but is stale — force-updating it in place"
  else
    echo "opening a new PR for $branch"
  fi

  run git checkout "$BASE_BRANCH"
  run git branch -D "$branch"
  if ! run git checkout -b "$branch"; then
    echo "::error::failed to create branch $branch, skipping this group" >&2
    return 0
  fi

  local pr_body="Opened automatically by the daily version-check run."$'\n'
  if (( ${#ordered[@]} > 1 )); then
    pr_body+="Bundled because $(join_by ", " "${ordered[@]}") depend on each other."$'\n'
  fi
  pr_body+=$'\n'

  local failed=false name
  for name in "${ordered[@]}"; do
    local toml_path old_version new_version pkgbase distro
    toml_path="$(dirty_field "$name" toml_path)"
    old_version="$(dirty_field "$name" old_version)"
    new_version="$(dirty_field "$name" new_version)"
    pkgbase="$(dirty_field "$name" pkgbase)"
    distro="$(dirty_field "$name" distro)"

    if ! grep -qF "version = \"${old_version}\"" "$toml_path"; then
      echo "::error::failed to prepare PR for $branch: couldn't find version = \"${old_version}\" in $toml_path" >&2
      failed=true
      break
    fi
    sed -i "s|version = \"${old_version}\"|version = \"${new_version}\"|" "$toml_path"

    local subject="$name: update to $new_version"
    run git add "$toml_path"
    if ! run git commit -m "$subject"; then
      echo "::error::failed to prepare PR for $branch: git commit failed for $name" >&2
      failed=true
      break
    fi

    local index_url_backend="$repo_root/backends/$distro/index-url.sh"
    local index_url=""
    [[ -x "$index_url_backend" ]] && index_url="$("$index_url_backend" "$pkgbase" 2>/dev/null || true)"
    if [[ -n "$index_url" ]]; then
      pr_body+="- \`$subject\` — $index_url"$'\n'
    else
      pr_body+="- \`$subject\`"$'\n'
    fi
  done

  if [[ "$failed" != true ]] && ! retry_run git push --force origin "$branch"; then
    failed=true
  fi

  if [[ "$failed" != true ]]; then
    local title=""
    for name in "${ordered[@]}"; do
      local seg="$name: update to $(dirty_field "$name" new_version)"
      if [[ -z "$title" ]]; then title="$seg"; else title+="; $seg"; fi
    done

    if [[ -n "$open_pr_number" ]]; then
      if retry_run gh pr edit "$open_pr_number" --title "$title" --body "$pr_body"; then
        echo "updated PR #$open_pr_number ($branch)"
      else
        failed=true
      fi
    else
      if retry_run gh pr create --title "$title" --body "$pr_body" --head "$branch" --base "$BASE_BRANCH"; then
        printf '%s\n' "$run_stdout"
      else
        failed=true
      fi
    fi
  fi

  [[ "$failed" == true ]] && echo "::error::failed to prepare PR for $branch" >&2

  run git checkout "$BASE_BRANCH"
  run git branch -D "$branch"
  return 0
}

main() {
  "$script_dir/../registry/load_registry.sh" --registry-root "$registry_root" > "$work_dir/entries.json"

  jq -c '[.[] | select(.autoupdate == true and .enabled == true)]' "$work_dir/entries.json" > "$work_dir/candidates.json"
  if [[ "$(jq 'length' "$work_dir/candidates.json")" -eq 0 ]]; then
    echo "no autoupdate packages configured"
    return 0
  fi

  # --- fetch upstream info, grouped by distro ---
  echo '{}' > "$work_dir/info.json"
  local distros
  distros="$(jq -r '[.[].distro] | unique | .[]' "$work_dir/candidates.json")"
  while IFS= read -r distro; do
    [[ -z "$distro" ]] && continue
    local backend="$repo_root/backends/$distro/fetch-info.sh"
    if [[ ! -x "$backend" ]]; then
      echo "::warning::no fetch-info.sh backend for distro '$distro', skipping its autoupdate candidates" >&2
      continue
    fi
    jq -c --arg d "$distro" '[.[] | select(.distro == $d) | .name]' "$work_dir/candidates.json" \
      | "$backend" > "$work_dir/distro_info.json"
    jq -cs '.[0] + .[1]' "$work_dir/info.json" "$work_dir/distro_info.json" > "$work_dir/info.json.new"
    mv "$work_dir/info.json.new" "$work_dir/info.json"
  done <<<"$distros"
  rm -f "$work_dir/distro_info.json"

  # --- warn about candidates with no upstream info at all ---
  # ($q holds a literal single-quote — can't embed one directly in the jq
  # program text below, since the whole program is itself wrapped in
  # single quotes for bash.)
  jq -r --slurpfile info "$work_dir/info.json" --arg q "'" '
    ($info[0]) as $info
    | .[] | select($info[.name] == null)
    | "::warning::upstream has no package named " + $q + .name + $q + " (pkgbase " + $q + .pkgbase + $q + "), skipping"
  ' "$work_dir/candidates.json" >&2

  # --- dirty set: candidates whose upstream version differs ---
  jq -c --slurpfile info "$work_dir/info.json" '
    ($info[0]) as $info
    | [.[] | . as $e | ($info[$e.name].version // null) as $upstream
        | select($upstream != null and $upstream != $e.version)
        | {name: $e.name, toml_path: $e.toml_path, old_version: $e.version,
           new_version: $upstream, pkgbase: $e.pkgbase, distro: $e.distro}
      ]
  ' "$work_dir/candidates.json" > "$work_dir/dirty_list.json"

  if [[ "$(jq 'length' "$work_dir/dirty_list.json")" -eq 0 ]]; then
    echo "all autoupdate packages are already up to date"
    return 0
  fi

  jq --arg root "$registry_root/" '
    map({(.name): {toml_path: .toml_path, rel_path: (.toml_path | ltrimstr($root)),
      old_version: .old_version, new_version: .new_version, pkgbase: .pkgbase, distro: .distro}}) | add
  ' "$work_dir/dirty_list.json" > "$work_dir/dirty.json"

  # --- dependency graph among CANDIDATES (depgraph's own --subset
  # restriction, applied below, narrows this to edges within the dirty
  # set only — grouping only cares whether two packages that are BOTH
  # currently out of date depend on each other, not on any candidate
  # that happens to already be up to date) ---
  jq -r -s --slurpfile info "$work_dir/info.json" '
    .[0] as $entries | ($info[0]) as $info | ([$entries[].name]) as $tracked
    | $entries[] | .name as $n
    | (($info[$n].depends // []) | map(select(. as $d | $tracked | index($d))) | unique) as $deps
    | "\($n)\t\($deps | join(","))"
  ' "$work_dir/candidates.json" > "$work_dir/graph.txt"

  jq -r 'keys[]' "$work_dir/dirty.json" | LC_ALL=C sort -u > "$work_dir/dirty_names.txt"

  "$depgraph" components --subset "$work_dir/dirty_names.txt" < "$work_dir/graph.txt" > "$work_dir/components.txt"

  local component_line
  while IFS= read -r component_line; do
    [[ -z "$component_line" ]] && continue
    tr ' ' '\n' <<<"$component_line" > "$work_dir/component_subset.txt"
    local ordered_str
    ordered_str="$("$depgraph" toposort --subset "$work_dir/component_subset.txt" < "$work_dir/graph.txt" | tr '\n' ' ')"
    local -a ordered
    read -ra ordered <<<"$ordered_str"
    process_group "${ordered[@]}"
  done < "$work_dir/components.txt"

  return 0
}

main
exit $?
