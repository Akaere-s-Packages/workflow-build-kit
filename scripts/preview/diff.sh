#!/usr/bin/env bash
set -euo pipefail

# Print a Markdown PR-comment body comparing a freshly built package
# against what's currently published — read from WebSite-Kit's public
# packageDetails JSON on GitHub Pages. No MinIO/GPG credentials needed: this
# job is deliberately secret-free so it's safe to run even on PRs from
# forks. Was scripts/preview/diff.py — 100% generic, no Arch-specific
# content, ported straight across.
#
# Usage:
#   diff.sh --name asusctl --old-version 6.4.0-1 --new-version 6.4.1-1
#           --build-status success --job-url <url>
#           --file-list <path to file_list.json>  # only when build-status=success
#           --published-base-url https://packages.pysio.online

# GitHub rejects an issue/PR comment body over 65536 characters outright
# (real failure: visual-studio-code-bin's diff — ~9000 files, nearly all of
# them re-sized by the version bump — produced a ~270000-char table and the
# whole `comment` job step failed with a 422). The rest of this comment
# (header/version/status/size-summary/anchor) is at most a few hundred
# characters, so budgeting well under the real limit for the table rows
# leaves a large, safe margin regardless of how many packages this PR
# touches or how long their paths are.
MAX_ROWS_CHARS=55000

name="" old_version="" new_version="" build_status="" job_url="" file_list="" published_base_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --old-version) old_version="$2"; shift 2 ;;
    --new-version) new_version="$2"; shift 2 ;;
    --build-status) build_status="$2"; shift 2 ;;
    --job-url) job_url="$2"; shift 2 ;;
    --file-list) file_list="$2"; shift 2 ;;
    --published-base-url) published_base_url="$2"; shift 2 ;;
    *) echo "diff.sh: unrecognized argument: $1" >&2; exit 2 ;;
  esac
done

: "${name:?--name required}"
: "${new_version:?--new-version required}"
: "${job_url:?--job-url required}"
: "${published_base_url:?--published-base-url required}"
case "$build_status" in
  success|failure) ;;
  *) echo "diff.sh: --build-status must be 'success' or 'failure'" >&2; exit 2 ;;
esac

# Same B/KB/MB/GB step-down as the old fmt_delta(), including its rounding
# rule: whole bytes have no decimal place, everything else gets one.
fmt_delta() {
  awk -v n="$1" 'BEGIN {
    sign = (n >= 0) ? "+" : "-"
    if (n < 0) n = -n
    split("B KB MB GB", units, " ")
    val = n
    for (i = 1; i <= 4; i++) {
      if (val < 1024 || units[i] == "GB") {
        if (units[i] == "B") printf "%s%.0f %s", sign, val, units[i]
        else printf "%s%.1f %s", sign, val, units[i]
        exit
      }
      val /= 1024
    }
  }'
}

# Prints the published packageDetails JSON on stdout, or nothing at all if
# there is none yet (a genuine 404) *or* the fetch failed for any other
# reason (network hiccup, site briefly down, invalid JSON, ...). Either way
# the diff degrades to "nothing to compare against" rather than crashing
# the whole PR check — this job has no credentials to fall back on, so
# best-effort is all it can do.
fetch_published() {
  local base_url="$1" pkg_name="$2"
  local url="${base_url%/}/packageDetails/${pkg_name}.json"
  local body_file err_file http_code
  body_file="$(mktemp)"
  err_file="$(mktemp)"

  if http_code="$(curl -sS -L --max-time 15 -o "$body_file" -w '%{http_code}' "$url" 2>"$err_file")"; then
    :
  else
    echo "::warning::couldn't fetch published data for $pkg_name ($(cat "$err_file")), diffing against nothing" >&2
    rm -f "$body_file" "$err_file"
    return
  fi
  rm -f "$err_file"

  if [[ "$http_code" == "404" ]]; then
    rm -f "$body_file"
    return
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "::warning::couldn't fetch published data for $pkg_name (HTTP $http_code), diffing against nothing" >&2
    rm -f "$body_file"
    return
  fi
  if ! jq -e . "$body_file" >/dev/null 2>&1; then
    echo "::warning::couldn't fetch published data for $pkg_name (invalid JSON), diffing against nothing" >&2
    rm -f "$body_file"
    return
  fi
  cat "$body_file"
  rm -f "$body_file"
}

anchor="<!-- workflow-build-kit:${name} -->"
lines=()
lines+=("### 📦 ${name} build preview" "")
lines+=("Version: \`${old_version:-(new)}\` -> \`${new_version}\`")

if [[ "$build_status" == "failure" ]]; then
  lines+=("Build: FAILED ([view log](${job_url}))" "" "$anchor")
  printf '%s\n' "${lines[@]}"
  exit 0
fi

lines+=("Build: succeeded ([view log](${job_url}))" "")

new_files_json='{"files":[],"package_size_bytes":0}'
if [[ -n "$file_list" && -f "$file_list" ]]; then
  new_files_json="$(cat "$file_list")"
fi

published_present=false
published_json='{}'
published_raw="$(fetch_published "$published_base_url" "$name")"
if [[ -n "$published_raw" ]]; then
  published_json="$published_raw"
  published_present=true
fi

# Written to temp files, not kept as bash variables passed via --argjson:
# a package with several thousand files (the real case that motivated
# MAX_ROWS_CHARS below) produces a path->size map past what's safe to hand
# a subprocess as a single command-line argument.
new_map_file="$(mktemp)"
old_map_file="$(mktemp)"
jq -c '[.files[]? | {(.path): .size_bytes}] | add // {}' <<<"$new_files_json" > "$new_map_file"
new_total="$(jq -r '.package_size_bytes // ([.files[]?.size_bytes] | add // 0)' <<<"$new_files_json")"
jq -c '[.files[]? | {(.path): .size_bytes}] | add // {}' <<<"$published_json" > "$old_map_file"
old_total="$(jq -r '.package_size_bytes // ([.files[]?.size_bytes] | add // 0)' <<<"$published_json")"

# Three independently-sorted-by-path groups (added, then removed, then
# changed), not one global sort across all of them — matches the old
# script's three separate `sorted(...)` calls exactly. One pass with O(1)
# object-key lookups per entry (not repeated key-list set-difference), so
# this stays fast even for a package with several thousand files.
rows_tsv="$(jq -rn --slurpfile new_arr "$new_map_file" --slurpfile old_arr "$old_map_file" '
  ($new_arr[0]) as $n | ($old_arr[0]) as $o |
  ( [ $n | to_entries[] | select($o[.key] == null) | [.key, .value] ]
    | sort_by(.[0]) | map("added\t" + .[0] + "\t" + (.[1] | tostring)) ) +
  ( [ $o | to_entries[] | select($n[.key] == null) | [.key, .value] ]
    | sort_by(.[0]) | map("removed\t" + .[0] + "\t" + ((-.[1]) | tostring)) ) +
  ( [ $n | to_entries[] | select($o[.key] != null and .value != $o[.key]) | [.key, (.value - $o[.key])] ]
    | sort_by(.[0]) | map("changed\t" + .[0] + "\t" + (.[1] | tostring)) )
  | .[]
')"
rm -f "$new_map_file" "$old_map_file"

shown_rows=()
budget=$MAX_ROWS_CHARS
omitted=0
total_rows=0
if [[ -n "$rows_tsv" ]]; then
  while IFS=$'\t' read -r row_status row_path row_delta; do
    [[ -z "$row_status" ]] && continue
    total_rows=$((total_rows + 1))
    row="| ${row_status} | \`${row_path}\` | $(fmt_delta "$row_delta") |"
    if (( budget - (${#row} + 1) < 0 )); then
      omitted=$((omitted + 1))
      continue
    fi
    shown_rows+=("$row")
    budget=$((budget - (${#row} + 1)))
  done <<<"$rows_tsv"
fi

if (( total_rows > 0 )); then
  lines+=("| Status | File | Size change |" "|---|---|---|")
  lines+=("${shown_rows[@]}")
  if (( omitted > 0 )); then
    noun="file"; (( omitted != 1 )) && noun="files"
    lines+=("| _(truncated)_ | _${omitted} more ${noun} not shown — comment size limit_ | |")
  fi
  lines+=("")
elif [[ "$published_present" != true ]]; then
  lines+=("_(no published version to compare against yet — these are all of this package's files)_" "")
fi

size_line="$(awk -v old="$old_total" -v new="$new_total" -v delta="$(fmt_delta "$((new_total - old_total))")" \
  'BEGIN { printf "Package size: %.1f MB -> %.1f MB (%s)", old/1024/1024, new/1024/1024, delta }')"
lines+=("$size_line" "" "$anchor")

printf '%s\n' "${lines[@]}"
