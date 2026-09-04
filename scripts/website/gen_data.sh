#!/usr/bin/env bash
set -euo pipefail

# Generate WebSite-Kit's src/_data/{packages.json,stats.json,updates.json}
# and src/_data/packageDetails/<name>.json from the Registry + this run's
# build artifacts. Was scripts/website/gen_data.py. Distro-agnostic:
# upstream metadata comes from each package's own
# backends/<distro>/fetch-info.sh / fetch-sources.sh, never AUR directly.
#
# Every run refreshes upstream-sourced fields (description, url, licenses,
# maintainer, submitter, votes, popularity, first_submitted) for every
# tracked package from one batched call per distro, then refreshes each
# package's source list from its pkgbase's own sources.
#
# Build-derived fields (files, package_size_bytes, dependencies with repo
# classification, packager, build_status, build_run_url, last_updated,
# version) only change for packages this run actually (re)built — everyone
# else keeps whatever is already committed in the WebSite-Kit checkout, so a
# build failure never overwrites the last known-good published state, and
# "last_updated" genuinely means "last time we published", not "last time
# this script ran".
#
# Usage:
#   gen_data.sh --registry-root <Registry checkout>
#               --website-data-dir <WebSite-Kit checkout>/src/_data
#               [--built <built_packages.json>]
#
# built_packages.json (written by the calling workflow, one entry per
# package the `build` job touched this run):
#   [{"type","name","pkgbase","build_status","job_url","artifact_dir",
#     "filename","sha256"}, ...]
# build_status is one of: published | build_failed | publish_failed
# artifact_dir must contain file_list.json and build_meta.json when
# build_status == "published" (see backends/<distro>/build.sh).
# filename/sha256 are the exact published package file's name and digest —
# set only when this package was actually signed and uploaded this run,
# null otherwise. Passed straight through to packageDetails/<name>.json so
# the website can point users at `gh attestation verify <filename> --repo
# ...` for the GitHub Artifact Attestation build-publish.yml's publish job
# generates for that same file.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

registry_root="" website_data_dir="" built_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-root) registry_root="$2"; shift 2 ;;
    --website-data-dir) website_data_dir="$2"; shift 2 ;;
    --built) built_path="$2"; shift 2 ;;
    *) echo "gen_data.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done
: "${registry_root:?--registry-root required}"
: "${website_data_dir:?--website-data-dir required}"
registry_root="$(cd "$registry_root" && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

"$script_dir/../registry/load_registry.sh" --registry-root "$registry_root" > "$work_dir/entries.json"

if [[ -n "$built_path" && -f "$built_path" ]]; then
  cp "$built_path" "$work_dir/built_list.json"
else
  echo '[]' > "$work_dir/built_list.json"
fi

details_dir="$website_data_dir/packageDetails"
mkdir -p "$details_dir"

# --- fetch upstream info, grouped by distro (each distro's own backend
# answers for its own packages only) ---
echo '{}' > "$work_dir/info.json"
distros="$(jq -r '[.[].distro] | unique | .[]' "$work_dir/entries.json")"
while IFS= read -r distro; do
  [[ -z "$distro" ]] && continue
  backend="$repo_root/backends/$distro/fetch-info.sh"
  if [[ -x "$backend" ]]; then
    jq -c --arg d "$distro" '[.[] | select(.distro == $d) | .name]' "$work_dir/entries.json" \
      | "$backend" > "$work_dir/distro_info.json"
    jq -cs '.[0] + .[1]' "$work_dir/info.json" "$work_dir/distro_info.json" > "$work_dir/info.json.new"
    mv "$work_dir/info.json.new" "$work_dir/info.json"
  else
    echo "::warning::no fetch-info.sh backend for distro '$distro', its packages get no upstream metadata refresh" >&2
  fi
done <<<"$distros"
rm -f "$work_dir/distro_info.json"

# --- fetch sources, once per (distro, pkgbase) pair — split packages
# sharing a pkgbase share their source list too ---
echo '{}' > "$work_dir/sources.json"
jq -r '[.[] | {pkgbase, distro}] | unique_by([.pkgbase, .distro]) | .[] | "\(.distro)\t\(.pkgbase)"' "$work_dir/entries.json" \
  | while IFS=$'\t' read -r distro pkgbase; do
      [[ -z "$pkgbase" ]] && continue
      backend="$repo_root/backends/$distro/fetch-sources.sh"
      [[ -x "$backend" ]] || continue
      if "$backend" "$pkgbase" > "$work_dir/one_source.json" 2>/dev/null; then
        jq -c --arg pb "$pkgbase" --slurpfile s "$work_dir/one_source.json" '.[$pb] = $s[0]' "$work_dir/sources.json" > "$work_dir/sources.json.new"
        mv "$work_dir/sources.json.new" "$work_dir/sources.json"
      fi
      # On failure, sources.json simply isn't updated for this pkgbase —
      # the per-package merge below treats "no entry here" as "don't
      # touch existing sources", matching fetch-sources.sh's own contract
      # (nonzero exit -> caller keeps prior data).
    done
rm -f "$work_dir/one_source.json"

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Prints one toml file's first-added-to-the-Registry date (ISO8601, UTC),
# or nothing if that can't be determined (e.g. a shallow checkout).
first_added_date() {
  local rel_path="$1" earliest
  earliest="$(git -C "$registry_root" log --follow --diff-filter=A --format=%aI -- "$rel_path" 2>/dev/null | tail -1)"
  [[ -z "$earliest" ]] && return
  date -u -d "$earliest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
}

# Merges one package's registry entry + upstream info + this run's build
# output + whatever packageDetails/<name>.json already existed into the
# final detail object. Mirrors gen_data.py's build_detail() field-by-field,
# in the same order (later steps' "keep the existing value" fallbacks
# depend on earlier steps not having touched that field yet).
build_detail() {
  jq -n \
    --slurpfile entry_arr <(printf '%s' "$1") \
    --slurpfile aur_arr <(printf '%s' "$2") \
    --slurpfile built_arr <(printf '%s' "$3") \
    --slurpfile existing_arr <(printf '%s' "$4") \
    --slurpfile sources_arr <(printf '%s' "$5") \
    --slurpfile build_meta_arr <(printf '%s' "$6") \
    --slurpfile file_list_arr <(printf '%s' "$7") \
    --arg now_iso "$now_iso" '
    ($entry_arr[0]) as $entry | ($aur_arr[0]) as $aur | ($built_arr[0]) as $built
    | ($existing_arr[0] // {}) as $base | ($sources_arr[0]) as $sources
    | ($build_meta_arr[0] // {}) as $build_meta | ($file_list_arr[0] // {}) as $file_list
    | $base
    | .name = $entry.name
    | .pkgbase = $entry.pkgbase
    | .distro = $entry.distro
    | .source_type = $entry.type
    | .maintainer = ($aur.maintainer // null)
    | .submitter = ($aur.submitter // null)
    | .votes = ($aur.votes // null)
    | .popularity = ($aur.popularity // null)
    | .first_submitted = (if $aur.first_submitted then $aur.first_submitted else (.first_submitted // null) end)
    | .description = (if $build_meta.description then $build_meta.description
                       elif $aur.description then $aur.description
                       else (.description // null) end)
    | .url = (if $build_meta.url then $build_meta.url
              elif $aur.url then $aur.url
              else (.url // null) end)
    | .licenses = (if (($build_meta.licenses // []) | length) > 0 then $build_meta.licenses
                   elif (($aur.license // []) | length) > 0 then $aur.license
                   else (.licenses // []) end)
    | (if $sources != null then .sources = $sources else . end)
    | if $built == null then
        .version = (.version // $entry.version)
        | .build_status = (.build_status // "unknown")
        | .build_run_url = (.build_run_url // null)
        | .package_size_bytes = (.package_size_bytes // null)
        | .dependencies = (.dependencies // [])
        | .sources = (.sources // [])
        | .files = (.files // [])
        | .last_updated = (.last_updated // null)
        | .packager = (.packager // null)
        | .filename = (.filename // null)
        | .sha256 = (.sha256 // null)
      else
        .build_status = $built.build_status
        | .build_run_url = ($built.job_url // null)
        | if $built.build_status == "published" then
            .version = $entry.version
            | .last_updated = $now_iso
            | .packager = ($build_meta.packager // null)
            | .dependencies = ($build_meta.dependencies // [])
            | .package_size_bytes = ($file_list.package_size_bytes // null)
            | .files = ($file_list.files // [])
            | .filename = ($built.filename // null)
            | .sha256 = ($built.sha256 // null)
            | .sources = (.sources // [])
          else
            .version = (.version // $entry.version)
            | .last_updated = (.last_updated // null)
            | .packager = (.packager // null)
            | .dependencies = (.dependencies // [])
            | .sources = (.sources // [])
            | .files = (.files // [])
            | .package_size_bytes = (.package_size_bytes // null)
            | .filename = null
            | .sha256 = null
          end
      end
  '
}

# now/week-ago/year-ago cutoffs, as epoch seconds, computed once.
now_epoch="$(date -u +%s)"
week_ago_epoch=$((now_epoch - 7 * 86400))
year_ago_epoch=$((now_epoch - 365 * 86400))

packages_summary_file="$work_dir/packages_summary.ndjson"
updates_file="$work_dir/updates.ndjson"
: > "$packages_summary_file"
: > "$updates_file"

maintainers_file="$work_dir/maintainers.txt"
: > "$maintainers_file"
orphan_count=0 added_7_days=0 never_updated=0 outdated=0 updated_7_days=0 updated_year=0

entry_count="$(jq 'length' "$work_dir/entries.json")"
for (( i = 0; i < entry_count; i++ )); do
  entry_json="$(jq -c ".[$i]" "$work_dir/entries.json")"
  name="$(jq -r '.name' <<<"$entry_json")"
  pkgbase="$(jq -r '.pkgbase' <<<"$entry_json")"
  toml_path="$(jq -r '.toml_path' <<<"$entry_json")"

  aur_json="$(jq -c --arg n "$name" '.[$n] // {}' "$work_dir/info.json")"
  built_json="$(jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // null' "$work_dir/built_list.json")"

  existing_path="$details_dir/$name.json"
  if [[ -f "$existing_path" ]]; then
    existing_json="$(cat "$existing_path")"
  else
    existing_json="null"
  fi

  sources_json="$(jq -c --arg pb "$pkgbase" '.[$pb] // null' "$work_dir/sources.json")"

  build_meta_json="{}"
  file_list_json="{}"
  if [[ "$(jq -r '.build_status // empty' <<<"$built_json")" == "published" ]]; then
    artifact_dir="$(jq -r '.artifact_dir' <<<"$built_json")"
    [[ -f "$artifact_dir/build_meta.json" ]] && build_meta_json="$(cat "$artifact_dir/build_meta.json")"
    [[ -f "$artifact_dir/file_list.json" ]] && file_list_json="$(cat "$artifact_dir/file_list.json")"
  fi

  detail_json="$(build_detail "$entry_json" "$aur_json" "$built_json" "$existing_json" "$sources_json" "$build_meta_json" "$file_list_json")"
  jq '.' <<<"$detail_json" > "$existing_path"
  # Also kept as a file (not just the $detail_json bash variable) for the
  # two --slurpfile uses below — a package's `files` array (thousands of
  # entries for some real packages) is too large to safely pass as a
  # single --argjson command-line argument.
  cp "$existing_path" "$work_dir/current_detail.json"

  maintainer="$(jq -r '.maintainer // empty' <<<"$detail_json")"
  if [[ -n "$maintainer" ]]; then
    echo "$maintainer" >> "$maintainers_file"
  else
    orphan_count=$((orphan_count + 1))
  fi

  rel_path="${toml_path#"$registry_root"/}"
  added="$(first_added_date "$rel_path")"
  if [[ -n "$added" ]]; then
    added_epoch="$(date -u -d "$added" +%s 2>/dev/null || true)"
    [[ -n "$added_epoch" && "$added_epoch" -ge "$week_ago_epoch" ]] && added_7_days=$((added_7_days + 1))
  fi

  [[ "$(jq -r '.build_status' <<<"$detail_json")" == "unknown" ]] && never_updated=$((never_updated + 1))

  last_updated="$(jq -r '.last_updated // empty' <<<"$detail_json")"
  if [[ -n "$last_updated" ]]; then
    lu_epoch="$(date -u -d "$last_updated" +%s 2>/dev/null || true)"
    if [[ -n "$lu_epoch" ]]; then
      [[ "$lu_epoch" -ge "$week_ago_epoch" ]] && updated_7_days=$((updated_7_days + 1))
      [[ "$lu_epoch" -ge "$year_ago_epoch" ]] && updated_year=$((updated_year + 1))
    fi
  fi

  aur_version="$(jq -r '.version // empty' <<<"$aur_json")"
  detail_version="$(jq -r '.version // empty' <<<"$detail_json")"
  if [[ -n "$aur_version" && "$aur_version" != "$detail_version" ]]; then
    outdated=$((outdated + 1))
  fi

  jq -cn --arg name "$name" --arg pkgbase "$pkgbase" --slurpfile d "$work_dir/current_detail.json" '
    ($d[0]) as $d
    | {name: $name, pkgbase: $pkgbase, distro: $d.distro, source_type: $d.source_type,
       version: $d.version, description: $d.description, maintainer: $d.maintainer,
       last_updated: $d.last_updated, build_status: $d.build_status, detail_url: ("/packages/" + $name + "/")}
  ' >> "$packages_summary_file"

  if [[ -n "$last_updated" ]]; then
    jq -cn --arg name "$name" --slurpfile d "$work_dir/current_detail.json" \
      '($d[0]) as $d | {name: $name, version: $d.version, date: $d.last_updated}' >> "$updates_file"
  fi
done

jq -cs 'sort_by(.name)' "$packages_summary_file" | jq '.' > "$website_data_dir/packages.json"

jq -cs 'sort_by(.date) | reverse | .[0:20]' "$updates_file" | jq '.' > "$website_data_dir/updates.json"

maintainer_count="$(LC_ALL=C sort -u "$maintainers_file" | grep -c . || true)"

jq -n \
  --argjson packages "$entry_count" \
  --argjson orphan_packages "$orphan_count" \
  --argjson added_7_days "$added_7_days" \
  --argjson updated_7_days "$updated_7_days" \
  --argjson updated_year "$updated_year" \
  --argjson never_updated "$never_updated" \
  --argjson package_maintainers "$maintainer_count" \
  --argjson outdated "$outdated" \
  '{
    packages: $packages,
    orphan_packages: $orphan_packages,
    added_7_days: $added_7_days,
    updated_7_days: $updated_7_days,
    updated_year: $updated_year,
    never_updated: $never_updated,
    registered_users: 1,
    package_maintainers: $package_maintainers,
    my_packages: $packages,
    my_outdated: $outdated
  }' > "$website_data_dir/stats.json"

echo "wrote packages.json ($entry_count), updates.json, stats.json, and $entry_count packageDetails/*.json"
