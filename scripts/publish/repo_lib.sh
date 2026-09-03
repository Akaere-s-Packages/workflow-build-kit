#!/usr/bin/env bash
# Shared functions for publishing to the R2-backed pacman repo. Sourced by
# both minio.sh (publishes exactly one package, downloads/uploads the repo
# db around it — the standalone, run-outside-a-workflow path) and
# publish_all.sh (publishes a whole batch: signs and `repo-add`s every
# package into ONE local db, then uploads that db exactly once at the end,
# instead of every package in the batch doing its own full download/upload
# round-trip of files every other package in the same run already touched).
#
# Callers must set these globals before calling anything here:
#   repo_name, distro, alias_name, remote, db_file, files_file
# (see minio.sh / publish_all.sh for the exact derivation — identical in
# both). GPG_KEY_ID/GPG_PASSPHRASE and the R2_* secrets are read directly
# from the environment, same as before this was split out.

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

# GPG-signs one already-copied-into-cwd package file and folds it into the
# LOCAL db_file/files_file — purely local, no upload. Caller must have
# already `cp`'d pkg_basename into the cwd first.
#
# Both steps' exit statuses are checked explicitly rather than left to
# `set -e` to catch — this function is called as an `if` condition in
# publish_all.sh's batched path (`if sign_and_add ... && upload_package_file
# ...; then`), and bash's documented `set -e` behavior is that a compound
# command executing in a context where -e is being ignored (an if
# condition, here) makes -e ignored for EVERY command run inside it too —
# so without an explicit check, a failed gpg signature here would silently
# fall through to repo-add, and if repo-add itself happened to still
# succeed (it doesn't care about the per-package .sig file this step
# produces), the whole function would incorrectly report success.
sign_and_add() {
  local pkg_basename="$1" status
  # GPG_PASSPHRASE is optional: a signing key made specifically for
  # unattended CI use commonly has no passphrase at all. `--passphrase ""`
  # is the correct non-interactive way to sign with such a key — it's not
  # "no passphrase given", it's "the passphrase is the empty string", which
  # is what an unprotected private key actually expects.
  set +x  # never trace the passphrase itself
  gpg --batch --pinentry-mode loopback --passphrase "${GPG_PASSPHRASE:-}" \
    --detach-sign --local-user "${GPG_KEY_ID:?}" "$pkg_basename"
  status=$?
  set -x
  (( status == 0 )) || return "$status"
  repo-add -s -k "$GPG_KEY_ID" "$db_file" "$pkg_basename"
}

# Uploads one already-signed-and-added package's own file + signature.
# Always per-package (there's nothing to batch here — every package's
# bytes are unique) — unlike upload_repo below, which is the part worth
# not repeating once per package in a batch.
upload_package_file() {
  local pkg_basename="$1" sig_basename="$2"
  retry mc cp "$pkg_basename" "$sig_basename" "$remote/"
}

# Uploads the current LOCAL db/files (+ signature, + extensionless aliases)
# to R2. Call this exactly once after every package in a batch has gone
# through sign_and_add — not once per package — since it's the same six
# objects each time regardless of how many packages fed into the db.
#
# Chained with `&&`, not six bare statements: this is called as an `if`
# condition in publish_all.sh (`if upload_repo; then`), and per bash's
# documented `set -e` semantics, a compound command running where -e is
# ignored (an if condition) makes -e ignored for every command inside it —
# so without the explicit chain, an early upload failing here would still
# let later ones run, and the function would report success as long as the
# LAST of the six happened to succeed, silently losing the earlier failure.
upload_repo() {
  retry mc cp "$db_file" "$remote/$db_file" &&
  retry mc cp "$files_file" "$remote/$files_file" &&
  retry mc cp "${db_file}.sig" "$remote/${db_file}.sig" &&
  # pacman's default `Server = .../x86_64` + `[reponame]` setup actually
  # requests the EXTENSIONLESS name (reponame.db), not reponame.db.tar.gz —
  # the .tar.gz name is the "real" file, .db/.files are traditionally a
  # symlink to it on real mirrors. S3 has no symlinks, so we upload the same
  # bytes twice. Critically, the signature needs the same treatment: without
  # reponame.db.sig, `SigLevel = Required` fails signature verification the
  # moment a client fetches reponame.db instead of reponame.db.tar.gz.
  retry mc cp "$db_file" "$remote/${repo_name}.db" &&
  retry mc cp "${db_file}.sig" "$remote/${repo_name}.db.sig" &&
  retry mc cp "$files_file" "$remote/${repo_name}.files"
}

# --- retention: keep only the newest $2 *files* for package $1 ---
# A failed listing here just means this run's cleanup is skipped (`|| true`
# below) rather than the whole publish failing — the package is already
# safely up (and, in the db), and the next successful run will catch up on
# retention. Still worth a retry first since it's cheap.
#
# The filter below requires *exactly* three more hyphen-free tokens after
# "$name-" — [epoch:]pkgver, pkgrel, and arch — rather than a naive
# `.+-x86_64` glob. Two real reasons, not just tidiness:
#   1. arch isn't always x86_64 — an arch=(any) package (fonts, pure-data
#      packages: noto-fonts-sc is one right now) produces .../<pkgrel>-any.pkg.tar.zst,
#      which a hardcoded suffix simply never matches, silently disabling
#      retention for every such package.
#   2. `.+` is greedy enough to also match a DIFFERENT, longer package's
#      files whenever one tracked name is a literal prefix of another —
#      samsung-unified-driver-{common,printer,scanner} are exactly that
#      relative to samsung-unified-driver. Since pkgver/pkgrel/arch can
#      never themselves contain a hyphen (only [epoch:]pkgver can contain a
#      colon), requiring exactly three hyphen-free trailing tokens is enough
#      to reject "samsung-unified-driver-common-1.00.39-11-x86_64..." when
#      pruning plain "samsung-unified-driver" (that remainder splits into
#      four tokens, not three) — a looser pattern would quietly treat one
#      package's files as another's stale versions and delete them.
prune_old_versions() {
  local name="$1" keep_versions="$2"
  local existing f v placed i

  list_versions() { mc ls "$remote/"; }
  existing="$(retry list_versions | awk '{print $NF}' | grep -E "^${name}-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$" || true)"

  local versions=()
  local -A file_for_version=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" =~ ^${name}-([^-]+-[^-]+)-[^-]+\.pkg\.tar\.zst$ ]]; then
      v="${BASH_REMATCH[1]}"
      versions+=("$v")
      file_for_version["$v"]="$f"
    fi
  done <<< "$existing"

  # Insertion-sort descending by vercmp (newest first). Small N, O(n^2) is fine.
  local sorted=()
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
    local stale="${file_for_version[$v]}"
    echo "pruning old version: $stale"
    if ! retry mc rm "$remote/$stale" "$remote/${stale}.sig"; then
      echo "::warning::could not prune $stale; retention will retry on the next publish" >&2
    fi
  done
}
