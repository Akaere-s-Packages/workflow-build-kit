#!/usr/bin/env bash
set -euo pipefail

# archlinux backend: batched AUR RPC lookup, normalized into the
# distro-agnostic shape every backends/<distro>/fetch-info.sh must
# produce (see backends/README.md). Was aur_graph.py's fetch_aur_info() +
# dep_names(), merged into one normalized call so generic code
# (resolve_build_order.sh, scripts/update/check_updates.sh,
# scripts/website/gen_data.sh) never needs to know AUR RPC's own field
# names (Depends/MakeDepends/FirstSubmitted/...). A future AOSC backend's
# fetch-info.sh would read from the abbs tree instead and produce this
# same shape from it.
#
# Usage: fetch-info.sh
#   reads a JSON array of package NAMES from stdin (not pkgbase — a split
#   PKGBUILD's several pkgnames each have their own Depends/MakeDepends,
#   and AUR RPC's info action is queryable by the specific name, not just
#   pkgbase)
#
# Prints a JSON object: {"<name>": {
#   "version": "pkgver-pkgrel",
#   "pkgbase": str,             # AUR's PackageBase — usually == name, but
#                                # differs for a non-base pkgname of a
#                                # split PKGBUILD (e.g. Name
#                                # "ttf-ms-win11-auto-zh_cn" has PackageBase
#                                # "ttf-ms-win11-auto"). That name's own AUR
#                                # git namespace is an empty placeholder —
#                                # only the pkgbase's repo has real content
#                                # — so callers that clone/build from this
#                                # must use pkgbase, never name, for that.
#   "depends": ["name", ...],   # hard Depends+MakeDepends only (OptDepends
#                                # is a soft suggestion, not counted), names
#                                # only (version constraints stripped), NOT
#                                # restricted to Registry-tracked packages
#                                # — callers intersect with their own
#                                # tracked set themselves
#   "description": str|null, "url": str|null, "license": [str,...],
#   "maintainer": str|null, "submitter": str|null,
#   "votes": num|null, "popularity": num|null,
#   "first_submitted": "ISO8601"|null
# }, ...}
# A name AUR doesn't know at all is simply absent from the result — never
# a null/error entry.
#
# Retries the whole batched call a few times before giving up (a
# transient AUR RPC hiccup shouldn't take down every script that calls
# this) — on final failure, prints {} and warns on stderr, rather than
# failing the whole calling script over one flaky lookup.

AUR_RPC="https://aur.archlinux.org/rpc/v5/info"
RETRY_ATTEMPTS=3
RETRY_DELAY_SECONDS=5

names_json="$(cat)"
[[ -z "$names_json" ]] && names_json='[]'

names="$(jq -r '(. // []) | unique | .[]' <<<"$names_json")"
if [[ -z "$names" ]]; then
  echo '{}'
  exit 0
fi

curl_args=()
while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  curl_args+=(--data-urlencode "arg[]=${n}")
done <<<"$names"

response_file="$(mktemp)"
success=false
for (( attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++ )); do
  if curl -fsS -L --max-time 30 --get "$AUR_RPC" "${curl_args[@]}" -o "$response_file" 2>/dev/null \
     && jq -e . "$response_file" >/dev/null 2>&1; then
    success=true
    break
  fi
  if (( attempt < RETRY_ATTEMPTS )); then
    echo "::warning::AUR RPC lookup failed (attempt $attempt/$RETRY_ATTEMPTS), retrying in ${RETRY_DELAY_SECONDS}s" >&2
    sleep "$RETRY_DELAY_SECONDS"
  fi
done

if [[ "$success" != true ]]; then
  echo "::warning::AUR RPC lookup failed after $RETRY_ATTEMPTS attempts, continuing with no AUR data" >&2
  echo '{}'
  rm -f "$response_file"
  exit 0
fi

jq -c '
  def strip_constraint:
    . as $d | reduce (">=","<=","=",">","<") as $sep ($d; split($sep) | .[0]);
  (.results // []) | map({
    key: .Name,
    value: {
      version: .Version,
      pkgbase: (.PackageBase // .Name),
      depends: ((.Depends // []) + (.MakeDepends // []) | map(strip_constraint) | unique),
      description: (.Description // null),
      url: (.URL // null),
      license: (.License // []),
      maintainer: (.Maintainer // null),
      submitter: (.Submitter // null),
      votes: (.NumVotes // null),
      popularity: (.Popularity // null),
      first_submitted: (if .FirstSubmitted then (.FirstSubmitted | todate) else null end)
    }
  }) | from_entries
' "$response_file"
rm -f "$response_file"
