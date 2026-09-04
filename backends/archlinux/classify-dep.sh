#!/usr/bin/env bash
set -euo pipefail

# archlinux backend: classifies dependency names as either "official"
# (pacman can install it directly from a sync repo — core/extra — no
# special handling needed) or "aur" (not there; needs to be built from
# AUR and chain-installed, the exact thing the Registry schema's
# `aur_depends` field and backends/archlinux/build.sh's aur_depends loop
# exist for). Part of the backends/<distro>/ contract (see
# backends/README.md) — used by scripts/update/add_package.sh to walk a
# requested package's dependency closure and decide which of its
# dependencies need their own Registry entry.
#
# Downloads the real core/extra sync databases (the same .db.tar.gz files
# `pacman -Sy` itself would fetch) from the official mirror and checks
# both %NAME% and %PROVIDES% against them — NOT a per-name web search.
# Checking %PROVIDES% specifically matters: plenty of real dependency
# names are virtual/provided rather than an actual pkgname (`cargo` is
# provided by `rust`, not its own package; `sh` by `bash`; etc.) — a
# lookup that only matches literal pkgnames (an early version of this
# script used archlinux.org's package search API, which only matches
# pkgname) misclassifies every such name as "aur" and then fails outright
# when AUR predictably doesn't have a package called "cargo" either. Not
# multilib: the base archlinux Docker image (what build.sh's build
# container actually is) ships multilib disabled by default, so a
# multilib-only name genuinely isn't installable there either — matching
# that instead of contradicting it.
#
# The downloaded databases are cached under a fixed temp path for up to
# an hour — scripts/update/add_package.sh calls this once per BFS
# iteration while walking a dependency closure, and re-downloading a
# multi-megabyte database on every single call would make anything but a
# trivial closure painfully slow.
#
# Usage: classify-dep.sh
#   reads a JSON array of dependency names from stdin
# Prints a JSON object: {"<name>": "official"|"aur", ...}
# Every input name is always present in the result — this never omits an
# entry the way fetch-info.sh does for an unrecognized name, since the
# caller needs a definite answer for every dependency to build a
# complete closure.

MIRROR="https://geo.mirror.pkgbuild.com"
REPOS=(core extra)
CACHE_DIR="${TMPDIR:-/tmp}/workflow-build-kit-archlinux-sync-db-cache"
CACHE_MAX_AGE_SECONDS=3600
RETRY_ATTEMPTS=3
RETRY_DELAY_SECONDS=5

names_json="$(cat)"
[[ -z "$names_json" ]] && names_json='[]'

names="$(jq -r '(. // []) | unique | .[]' <<<"$names_json")"
if [[ -z "$names" ]]; then
  echo '{}'
  exit 0
fi

mkdir -p "$CACHE_DIR"

fetch_db() {
  local repo="$1" dest="$2"
  local attempt
  for (( attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++ )); do
    if curl -fsS -L --max-time 60 "$MIRROR/$repo/os/x86_64/$repo.db" -o "$dest" 2>/dev/null; then
      return 0
    fi
    if (( attempt < RETRY_ATTEMPTS )); then
      echo "::warning::failed to download $repo.db (attempt $attempt/$RETRY_ATTEMPTS), retrying in ${RETRY_DELAY_SECONDS}s" >&2
      sleep "$RETRY_DELAY_SECONDS"
    fi
  done
  return 1
}

known_names_file="$CACHE_DIR/known-names.txt"
stamp_file="$CACHE_DIR/known-names.stamp"

now="$(date -u +%s)"
cache_fresh=false
if [[ -f "$known_names_file" && -f "$stamp_file" ]]; then
  cached_at="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  if [[ "$cached_at" =~ ^[0-9]+$ ]] && (( now - cached_at < CACHE_MAX_AGE_SECONDS )); then
    cache_fresh=true
  fi
fi

if [[ "$cache_fresh" != true ]]; then
  tmp_names_file="$(mktemp)"
  : > "$tmp_names_file"
  for repo in "${REPOS[@]}"; do
    db_file="$(mktemp)"
    if ! fetch_db "$repo" "$db_file"; then
      echo "::error::couldn't download $repo.db after $RETRY_ATTEMPTS attempts" >&2
      rm -f "$db_file" "$tmp_names_file"
      exit 1
    fi
    # Each package's `desc` entry lists %NAME% (one line) and an optional
    # %PROVIDES% block (one name per line, up to the next %FIELD%,
    # possibly version-constrained like "cargo=1.98.0") — collect both,
    # stripping any version constraint off provides entries the same way
    # every other dependency-name field in this project is stripped.
    #
    # GNU tar, not bsdtar: this script runs on the plain ubuntu-latest
    # host (dependency resolution happens before any Arch container is
    # ever started), and bsdtar isn't part of that runner image's default
    # toolset the way it is inside archlinux:base-devel (where it's
    # pulled in as a pacman/libarchive dependency) — confirmed absent
    # from GitHub's own runner-image manifest. GNU tar is unconditionally
    # present on any Linux runner and reads the exact same .db.tar.gz
    # format; --wildcards enables the glob pattern, -O extracts to
    # stdout — verified byte-for-byte identical output against bsdtar on
    # a real core.db before switching.
    tar -xzf "$db_file" --wildcards -O '*/desc' 2>/dev/null | awk '
      function strip_constraint(s) {
        split(s, a, /(>=|<=|=|>|<)/)
        return a[1]
      }
      /^%NAME%$/ { getline; print; next }
      /^%PROVIDES%$/ { in_provides = 1; next }
      /^%[A-Z]+%$/ { in_provides = 0 }
      in_provides && NF { print strip_constraint($0) }
    ' >> "$tmp_names_file"
    rm -f "$db_file"
  done
  LC_ALL=C sort -u -o "$known_names_file" "$tmp_names_file"
  rm -f "$tmp_names_file"
  echo "$now" > "$stamp_file"
fi

result="{}"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  classification="aur"
  grep -qxF "$name" "$known_names_file" && classification="official"
  result="$(jq -c --arg n "$name" --arg c "$classification" '. + {($n): $c}' <<<"$result")"
done <<<"$names"

echo "$result"
