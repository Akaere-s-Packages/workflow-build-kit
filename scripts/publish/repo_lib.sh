# Shared, distro-agnostic S3 (via `mc`) publish primitives. Sourced, not
# run standalone — by both minio.sh (publishes exactly one package,
# downloads/uploads the repo db around it) and publish_all.sh (publishes a
# whole batch). Neither script, nor this file, ever invokes repo-add/
# repo-remove/vercmp or anything else that only exists for pacman
# specifically — that lives entirely in backends/<distro>/repo_lib.sh,
# which callers source separately (see minio.sh, and the per-distro loop
# in publish_all.sh) once they know which distro they're publishing for.
# This split is what makes adding a second distro's repo format (a
# Debian-style apt-ftparchive/reprepro backend, say) a matter of adding a
# new backends/<distro>/repo_lib.sh, not touching this file or its callers.
#
# Callers must set `alias_name`/`remote`/`bucket` before calling anything
# here (see minio.sh / publish_all.sh for the exact derivation — identical
# in both).

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

mc_alias_set() {
  set +x  # never trace the credentials themselves
  mc alias set "$alias_name" "${R2_ENDPOINT:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" >/dev/null
  set -x
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

# Uploads one already-signed-and-indexed package's own file + signature.
# Always per-package (there's nothing to batch here — every package's
# bytes are unique) — unlike a repo-index upload (backends/<distro>/
# repo_lib.sh's upload_repo), which is the part worth not repeating once
# per package in a batch.
upload_package_file() {
  local pkg_basename="$1" sig_basename="$2"
  retry mc cp "$pkg_basename" "$sig_basename" "$remote/"
}

# Publishes the signing key's own ASCII-armored public key to the BUCKET
# ROOT (not under $remote, which is one distro's repo path — the key isn't
# tied to any one distro) so real users have somewhere real to `curl`/
# `pacman-key --add` it from, instead of having to dig a key ID out of a
# CI log (which is all this repo could offer before this existed). Caller
# must set `bucket` (just the bucket name, not the full alias/bucket/...
# remote path). Safe to call on every publish: the key itself essentially
# never changes, this just keeps the published copy in sync should it ever
# get rotated. Best-effort by design — call sites treat a failure here as
# a warning, not a reason to mark otherwise-successful package publishes
# as failed; the pacman repo itself doesn't depend on this file at all,
# only humans setting up a fresh machine do.
upload_public_key() {
  gpg --export --armor "${GPG_KEY_ID:?}" > "${repo_name}.gpg"
  retry mc cp "${repo_name}.gpg" "${alias_name}/${bucket:?}/${repo_name}.gpg"
}
