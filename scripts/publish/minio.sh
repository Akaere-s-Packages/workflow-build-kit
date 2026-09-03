#!/usr/bin/env bash
set -euo pipefail
# Trace every command by default (see build/package.sh for why). Unlike
# that script, this one DOES handle secrets (R2 keys, GPG passphrase) — the
# two lines that pass them as literal CLI args are individually wrapped in
# `set +x`/`set -x` below so their values never reach the trace output at
# all. Don't rely solely on GitHub's log redaction for that; this script
# can also be run locally with real secrets in the environment.
set -x

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

# Same retry() as build/package.sh: R2 is a network call like anything
# else, and worth surviving a transient blip rather than failing the
# whole publish over one.
retry() {
  local attempts=3 delay=5 n=1
  until "$@"; do
    if (( n >= attempts )); then
      echo "::error::command failed after $attempts attempts: $*" >&2
      return 1
    fi
    echo "::warning::command failed (attempt $n/$attempts), retrying in ${delay}s: $*" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}
# Downloads a repository metadata object, retrying failures other than a
# missing-object response. A missing object is valid only when both
# metadata files are absent on the first-ever publish; callers distinguish it
# with status 2 instead of silently treating every R2 error as missing.
#
# mc's actual wording for a missing key against a real Cloudflare R2 bucket
# is "Object does not exist" — NOT the raw S3 error code "NoSuchKey" that
# an earlier version of this check assumed (and that the test suite's fake
# `mc` stub had been echoing verbatim, so the test passed while the real
# thing didn't: a bootstrap publish against a genuinely-empty repo retried
# 3 times and hard-failed instead of proceeding to create the initial db).
# Matching "Object does not exist" specifically (not a broader "does not
# exist") matters: a *bucket*-level 404 ("The specified bucket does not
# exist") is a real misconfiguration — wrong R2_BUCKET — and must still
# fail loudly, not get silently treated as "first publish, going ahead".
download_metadata_file() {
  local source="$1" destination="$2"
  local attempts=3 delay=5 n=1 output

  while true; do
    if output="$(mc cp "$source" "$destination" 2>&1)"; then
      return 0
    fi
    if [[ "$output" == *"NoSuchKey"* || "$output" == *"Object does not exist"* ]]; then
      echo "repository metadata is absent: $source" >&2
      return 2
    fi
    echo "$output" >&2
    if (( n >= attempts )); then
      echo "::error::metadata download failed after $attempts attempts: $source" >&2
      return 1
    fi
    echo "::warning::metadata download failed (attempt $n/$attempts), retrying in ${delay}s: $source" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}

download_metadata_pair() {
  local db_state files_state status

  if download_metadata_file "$remote/$db_file" .; then
    db_state=present
  else
    status=$?
    case "$status" in
      2) db_state=missing ;;
      *) return "$status" ;;
    esac
  fi

  if download_metadata_file "$remote/$files_file" .; then
    files_state=present
  else
    status=$?
    case "$status" in
      2) files_state=missing ;;
      *) return "$status" ;;
    esac
  fi

  if [[ "$db_state" != "$files_state" ]]; then
    echo "::error::incomplete remote repository metadata: $db_file is $db_state, $files_file is $files_state" >&2
    return 1
  fi
  if [[ "$db_state" == missing ]]; then
    echo "repository metadata is absent; creating the initial repository" >&2
  fi
}


set +x  # never trace the credentials themselves
mc alias set "$alias_name" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" >/dev/null
set -x

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

# GPG_PASSPHRASE is optional: a signing key made specifically for
# unattended CI use commonly has no passphrase at all. `--passphrase ""`
# is the correct non-interactive way to sign with such a key — it's not
# "no passphrase given", it's "the passphrase is the empty string", which
# is what an unprotected private key actually expects.
set +x  # never trace the passphrase itself
gpg --batch --pinentry-mode loopback --passphrase "${GPG_PASSPHRASE:-}" \
  --detach-sign --local-user "${GPG_KEY_ID:?}" "$pkg_basename"
set -x
sig_basename="${pkg_basename}.sig"

repo-add -s -k "$GPG_KEY_ID" "$db_file" "$pkg_basename"

retry mc cp "$pkg_basename" "$sig_basename" "$remote/"
retry mc cp "$db_file" "$remote/$db_file"
retry mc cp "$files_file" "$remote/$files_file"
retry mc cp "${db_file}.sig" "$remote/${db_file}.sig"
# pacman's default `Server = .../x86_64` + `[reponame]` setup actually
# requests the EXTENSIONLESS name (reponame.db), not reponame.db.tar.gz —
# the .tar.gz name is the "real" file, .db/.files are traditionally a
# symlink to it on real mirrors. S3 has no symlinks, so we upload the same
# bytes twice. Critically, the signature needs the same treatment: without
# reponame.db.sig, `SigLevel = Required` fails signature verification the
# moment a client fetches reponame.db instead of reponame.db.tar.gz.
retry mc cp "$db_file" "$remote/${repo_name}.db"
retry mc cp "${db_file}.sig" "$remote/${repo_name}.db.sig"
retry mc cp "$files_file" "$remote/${repo_name}.files"

echo "published $pkg_basename"

# --- retention: keep only the newest $keep_versions *files* for $name ---
# A failed listing here just means this run's cleanup is skipped (`|| true`
# below) rather than the whole publish failing — the package we just
# published is already safely up, and the next successful run will catch
# up on retention. Still worth a retry first since it's cheap.
#
# The filter below requires *exactly* three more hyphen-free tokens after
# "$name-" — [epoch:]pkgver, pkgrel, and arch — rather than the old
# `.+-x86_64` glob. Two real reasons, not just tidiness:
#   1. arch isn't always x86_64 — an arch=(any) package (fonts, pure-data
#      packages: noto-fonts-sc is one right now) produces .../<pkgrel>-any.pkg.tar.zst,
#      which the old hardcoded suffix simply never matched, silently
#      disabling retention for every such package.
#   2. `.+` is greedy enough to also match a DIFFERENT, longer package's
#      files whenever one tracked name is a literal prefix of another —
#      samsung-unified-driver-{common,printer,scanner} are exactly that
#      relative to samsung-unified-driver. Since pkgver/pkgrel/arch can
#      never themselves contain a hyphen (only [epoch:]pkgver can contain a
#      colon), requiring exactly three hyphen-free trailing tokens is enough
#      to reject "samsung-unified-driver-common-1.00.39-11-x86_64..." when
#      pruning plain "samsung-unified-driver" (that remainder splits into
#      four tokens, not three) — the old pattern would have quietly treated
#      one package's files as another's stale versions and deleted them.
list_versions() { mc ls "$remote/"; }
existing="$(retry list_versions | awk '{print $NF}' | grep -E "^${name}-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$" || true)"

versions=()
declare -A file_for_version=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" =~ ^${name}-([^-]+-[^-]+)-[^-]+\.pkg\.tar\.zst$ ]]; then
    v="${BASH_REMATCH[1]}"
    versions+=("$v")
    file_for_version["$v"]="$f"
  fi
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
  stale="${file_for_version[$v]}"
  echo "pruning old version: $stale"
  if ! retry mc rm "$remote/$stale" "$remote/${stale}.sig"; then
    echo "::warning::could not prune $stale; retention will retry on the next publish" >&2
  fi
done
