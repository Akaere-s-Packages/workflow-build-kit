#!/usr/bin/env bash
set -euo pipefail

# Prints the latest Version (pkgver-pkgrel, as AUR itself reports it) for a
# pkgbase, or exits 1 if AUR has no such package.
#
# Usage: check_version.sh <pkgbase>

pkgbase="${1:?pkgbase required}"

response="$(curl -fsS --get "https://aur.archlinux.org/rpc/v5/info" --data-urlencode "arg[]=${pkgbase}")"

version="$(echo "$response" | jq -r '.results[0].Version // empty')"

if [[ -z "$version" ]]; then
  echo "AUR has no package named '${pkgbase}'" >&2
  exit 1
fi

echo "$version"
