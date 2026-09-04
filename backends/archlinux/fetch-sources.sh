#!/usr/bin/env bash
set -euo pipefail

# archlinux backend: fetch a pkgbase's source declarations from its
# .SRCINFO (via AUR's cgit mirror), normalized into the distro-agnostic
# shape every backends/<distro>/fetch-sources.sh must produce (see
# backends/README.md). Was gen_data.py's fetch_srcinfo_sources() +
# parse_sources().
#
# Usage: fetch-sources.sh <pkgbase>
# Prints a JSON array of {"name": str, "url": str (omitted if none)}, or
# nothing (exit 1) if the fetch failed after retrying — the caller decides
# whether that means "keep whatever was there before" (see
# scripts/website/gen_data.sh).

AUR_RPC_HOST="https://aur.archlinux.org"
RETRY_ATTEMPTS=3
RETRY_DELAY_SECONDS=5

pkgbase="${1:?pkgbase required}"
url="${AUR_RPC_HOST}/cgit/aur.git/plain/.SRCINFO?h=$(jq -rn --arg p "$pkgbase" '$p | @uri')"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

success=false
for (( attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++ )); do
  if curl -fsS -L --max-time 30 "$url" -o "$body_file" 2>/dev/null; then
    success=true
    break
  fi
  if (( attempt < RETRY_ATTEMPTS )); then
    echo "::warning::.SRCINFO lookup for $pkgbase failed (attempt $attempt/$RETRY_ATTEMPTS), retrying in ${RETRY_DELAY_SECONDS}s" >&2
    sleep "$RETRY_DELAY_SECONDS"
  fi
done

if [[ "$success" != true ]]; then
  echo "::warning::.SRCINFO lookup for $pkgbase failed after $RETRY_ATTEMPTS attempts; retaining prior sources" >&2
  exit 1
fi

# Parses each `source`/`source_<arch>` line's value: [alias::]location.
# location's VCS prefix (git+/hg+/svn+/bzr+) is stripped before checking
# whether what's left looks like a real URL. name is: the alias if given,
# else the URL's last path segment (query string dropped) if it looks
# like a URL, else the raw location as-is (a local/generated source with
# no alias and no URL — still worth listing by name). First occurrence of
# a given (name, url) pair wins; later duplicates are dropped (order
# preserved — NOT `unique_by`, which would re-sort instead of keeping
# file order).
jq -R -s -c '
  def strip_vcs_prefix:
    if startswith("git+") then .[4:]
    elif startswith("hg+") then .[3:]
    elif startswith("svn+") then .[4:]
    elif startswith("bzr+") then .[4:]
    else .
    end;

  def looks_like_url:
    startswith("https://") or startswith("http://") or startswith("ftp://");

  (split("\n")
   | [.[] | select(test(" = ")) | capture("^(?<key>.*?) = (?<value>.*)$") | .key |= gsub("^\\s+|\\s+$"; "")]
   | map(select(.key == "source" or (.key | startswith("source_"))))
   | map(
       ( if (.value | test("::")) then
           (.value | capture("^(?<alias>[^:]*)::(?<location>.*)$"))
         else
           {alias: "", location: .value}
         end
       ) as $parts
       | ($parts.location | strip_vcs_prefix) as $loc
       | ($loc | looks_like_url) as $is_url
       | (
           if $parts.alias != "" then $parts.alias
           elif $is_url then (($loc | split("#")[0] | rtrimstr("/")) | split("/") | .[-1])
           else $loc
           end
         ) as $name
       | select($name != "")
       | if $is_url then {name: $name, url: $loc} else {name: $name} end
     )
  ) as $entries
  | reduce $entries[] as $item ([[], {}];
      ($item.name + "\u0001" + ($item.url // "")) as $k
      | if .[1][$k] then . else [(.[0] + [$item]), (.[1] + {($k): true})] end
    )
  | .[0]
' "$body_file"
