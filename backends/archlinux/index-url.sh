#!/usr/bin/env bash
set -euo pipefail

# archlinux backend: prints the URL of a pkgbase's listing on AUR, the
# thing a human reviewing an autoPR would want to click through to. Part
# of the backends/<distro>/ contract (see backends/README.md) — kept as
# its own tiny script rather than hardcoded in the generic
# scripts/update/check_updates.sh, since a different distro's package
# index has a differently-shaped URL (or none at all).
#
# Usage: index-url.sh <pkgbase>

pkgbase="${1:?pkgbase required}"
echo "https://aur.archlinux.org/packages/${pkgbase}"
