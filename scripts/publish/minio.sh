#!/usr/bin/env bash
set -euo pipefail

# Publishes one already-built package to the MinIO-backed pacman repo (GPG
# signing it along the way), then deletes old *files* of that same package
# beyond the newest 3. A pacman repo db only ever points at ONE version per
# pkgname — repo-add replaces the previous entry outright — so "keep 3
# versions" is purely about leaving old package files downloadable for
# manual `pacman -U` downgrades, not about the db itself.
#
# Usage: minio.sh <name> <pkg-file>
# Required env: R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#               GPG_KEY_ID
# Optional env: GPG_PASSPHRASE (empty/unset if the signing key itself has
#               no passphrase — common for a key made just for CI use),
#               REPO_NAME (default "akaere"), KEEP_VERSIONS (default 3),
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
keep_versions="${KEEP_VERSIONS:-3}"
distro="${DISTRO:-archlinux}"
alias_name="akaere-minio"
remote="${alias_name}/${R2_BUCKET:?R2_BUCKET required}/${distro}/x86_64"

mc alias set "$alias_name" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" >/dev/null

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

db_file="${repo_name}.db.tar.gz"
files_file="${repo_name}.files.tar.gz"

# Absent on the very first-ever publish; that's fine, repo-add creates it.
mc cp "$remote/$db_file" . 2>/dev/null || true
mc cp "$remote/$files_file" . 2>/dev/null || true

cp "$pkg_file" .
pkg_basename="$(basename "$pkg_file")"

# GPG_PASSPHRASE is optional: a signing key made specifically for
# unattended CI use commonly has no passphrase at all. `--passphrase ""`
# is the correct non-interactive way to sign with such a key — it's not
# "no passphrase given", it's "the passphrase is the empty string", which
# is what an unprotected private key actually expects.
gpg --batch --pinentry-mode loopback --passphrase "${GPG_PASSPHRASE:-}" \
  --detach-sign --local-user "${GPG_KEY_ID:?}" "$pkg_basename"
sig_basename="${pkg_basename}.sig"

repo-add -s -k "$GPG_KEY_ID" "$db_file" "$pkg_basename"

mc cp "$pkg_basename" "$sig_basename" "$remote/"
mc cp "$db_file" "$remote/$db_file"
mc cp "$files_file" "$remote/$files_file"
mc cp "${db_file}.sig" "$remote/${db_file}.sig"
# pacman's default `Server = .../x86_64` + `[reponame]` setup actually
# requests the EXTENSIONLESS name (reponame.db), not reponame.db.tar.gz —
# the .tar.gz name is the "real" file, .db/.files are traditionally a
# symlink to it on real mirrors. S3 has no symlinks, so we upload the same
# bytes twice. Critically, the signature needs the same treatment: without
# reponame.db.sig, `SigLevel = Required` fails signature verification the
# moment a client fetches reponame.db instead of reponame.db.tar.gz.
mc cp "$db_file" "$remote/${repo_name}.db"
mc cp "${db_file}.sig" "$remote/${repo_name}.db.sig"
mc cp "$files_file" "$remote/${repo_name}.files"

echo "published $pkg_basename"

# --- retention: keep only the newest $keep_versions *files* for $name ---
existing="$(mc ls "$remote/" 2>/dev/null | awk '{print $NF}' | grep -E "^${name}-.+-x86_64\.pkg\.tar\.zst$" || true)"

versions=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  v="${f#"${name}"-}"
  v="${v%-x86_64.pkg.tar.zst}"
  versions+=("$v")
done <<< "$existing"

# Insertion-sort descending by vercmp (newest first). Small N, O(n^2) is fine.
sorted=()
for v in "${versions[@]}"; do
  placed=false
  for i in "${!sorted[@]}"; do
    if (( $(vercmp "$v" "${sorted[$i]}") > 0 )); then
      sorted=("${sorted[@]:0:$i}" "$v" "${sorted[@]:$i}")
      placed=true
      break
    fi
  done
  [[ $placed == true ]] || sorted+=("$v")
done

for v in "${sorted[@]:$keep_versions}"; do
  stale="${name}-${v}-x86_64.pkg.tar.zst"
  echo "pruning old version: $stale"
  mc rm "$remote/$stale" "$remote/${stale}.sig" 2>/dev/null || true
done
