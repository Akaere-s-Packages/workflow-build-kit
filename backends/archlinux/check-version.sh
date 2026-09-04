#!/usr/bin/env bash
set -euo pipefail

# archlinux backend: prints the latest Version (pkgver-pkgrel, as AUR
# itself reports it) for a pkgbase, or exits 1 if AUR has no such package.
# Part of the backends/<distro>/ contract (see backends/README.md) — every
# distro backend must provide a check-version.sh with this same interface.
#
# Usage: check-version.sh <pkgbase>

pkgbase="${1:?pkgbase required}"

# curl's own retry handling: --retry-all-errors covers transient network
# errors AUR occasionally throws (connection resets, brief timeouts).
response="$(curl -fsS --retry 3 --retry-delay 5 --retry-all-errors \
  --get "https://aur.archlinux.org/rpc/v5/info" --data-urlencode "arg[]=${pkgbase}")"

version="$(echo "$response" | jq -r '.results[0].Version // empty')"

if [[ -z "$version" ]]; then
  echo "AUR has no package named '${pkgbase}'" >&2
  exit 1
fi

echo "$version"
