#!/usr/bin/env bash
set -euo pipefail
# Trace every command by default (see build/package.sh for why). Unlike
# that script, this one DOES handle secrets (R2 keys, GPG passphrase) — the
# lines that pass them as literal CLI args are individually wrapped in
# `set +x`/`set -x` (in repo_lib.sh) so their values never reach the trace
# output at all. Don't rely solely on GitHub's log redaction for that; this
# script can also be run locally with real secrets in the environment.
set -x

# Publishes one already-built package to the MinIO-backed pacman repo (GPG
# signing it along the way), then deletes old *files* of that same package
# beyond the newest one. A pacman repo db only ever points at ONE version
# per pkgname — repo-add replaces the previous entry outright — so this is
# purely about not leaving stale package files (and R2 storage) behind,
# not about the db itself.
#
# Publishes a single package end-to-end: download the current db, sign +
# repo-add this one package into it, upload the db back, prune. For
# publishing a whole batch of packages in one job (as build-publish.yml's
# `publish` step does), use publish_all.sh instead — it reuses the same
# functions (see repo_lib.sh) but downloads/uploads the db exactly once for
# the entire batch rather than once per package.
#
# Usage: minio.sh <name> <pkg-file>
# Required env: R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#               GPG_KEY_ID
# Optional env: GPG_PASSPHRASE (empty/unset if the signing key itself has
#               no passphrase — common for a key made just for CI use),
#               REPO_NAME (default "akaere"), KEEP_VERSIONS (default 1),
#               DISTRO (default "archlinux")
#
# The bucket is laid out as <DISTRO>/<arch>/... rather than just <arch>/...
# at the root, because this MinIO bucket is meant to eventually host more
# than one distro's repo format (a Debian pool/dists layout, say) side by
# side — everything under archlinux/ is specifically the pacman repo.

name="${1:?package name required}"
pkg_file="${2:?built package path required}"
# Resolve to an absolute path *before* cd-ing into work_dir below — pkg_file
# is typically passed in relative to the caller's cwd (e.g. a downloaded
# artifact directory), and that relative path stops resolving correctly
# the moment we change directories.
pkg_file="$(cd "$(dirname "$pkg_file")" && pwd)/$(basename "$pkg_file")"

repo_name="${REPO_NAME:-akaere}"
keep_versions="${KEEP_VERSIONS:-1}"
distro="${DISTRO:-archlinux}"
alias_name="akaere-minio"
bucket="${R2_BUCKET:?R2_BUCKET required}"
remote="${alias_name}/${bucket}/${distro}/x86_64"

source "$(dirname "${BASH_SOURCE[0]}")/repo_lib.sh"

mc_alias_set

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

db_file="${repo_name}.db.tar.gz"
files_file="${repo_name}.files.tar.gz"

# An empty repository has neither metadata object. Anything else — including
# a transient R2 failure, bad credentials, or only one object being absent —
# must stop before repo-add could overwrite the existing package index.
download_metadata_pair

cp "$pkg_file" .
pkg_basename="$(basename "$pkg_file")"
sig_basename="${pkg_basename}.sig"

sign_and_add "$pkg_basename"
upload_package_file "$pkg_basename" "$sig_basename"
upload_repo

echo "published $pkg_basename"

if ! upload_public_key; then
  echo "::warning::couldn't publish the public key file (the package itself is still published correctly)" >&2
fi

prune_old_versions "$name" "$keep_versions"
