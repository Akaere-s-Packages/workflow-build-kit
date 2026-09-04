#!/usr/bin/env bash
set -euo pipefail
set -x

# Runs inside archlinux:base-devel (see build-publish.yml's `publish` job,
# which invokes this via `docker run` against the workspace checked out on
# the ubuntu-latest host) rather than directly on the host runner. repo-add
# and vercmp are shipped as part of the `pacman` package itself, not
# something `apt-get` on Ubuntu has any equivalent of, and there's no
# portable static binary for them worth fetching — the actual bug this
# fixed: publish was silently assumed to run on the bare host, and blew up
# with "repo-add: command not found" the first time a build made it this
# far. One container for the whole job (not one `docker run` per package)
# so the mc install and GPG import below only happen once, not once per
# built package.
#
# Signs and `repo-add`s every successfully-built package into ONE local db
# per distro, then uploads that db exactly once per distro — not once per
# package. A real batch (verified against a 26-package run) otherwise
# spends most of its wall-clock time re-fetching then re-uploading the same
# few-KB db.tar.gz/.sig/.files objects over and over, once per package that
# happens to publish successfully, even though every one of those round
# trips after the first is redundant: nothing outside this run's own
# packages could have changed the db in between. See repo_lib.sh for the
# shared sign/upload/prune functions minio.sh (the standalone,
# one-package-at-a-time path) also uses.
#
# Must run from the job workspace root (the directory holding `artifacts/`
# — this run's downloaded build-* artifacts —, `build-kit/` — this
# checkout of workflow-build-kit itself, for scripts/publish/repo_lib.sh —,
# and `registry/` — a checkout of the Registry repo itself, used only to
# read its current file tree so prune_removed_packages knows what SHOULD
# still be published; nothing here reads Registry file contents).
#
# Required env: R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#               GPG_PRIVATE_KEY (base64-encoded armored export)
# Optional env: GPG_PASSPHRASE (empty/unset if the signing key has none),
#               REPO_NAME (default "akaere"), KEEP_VERSIONS (default 1)
#
# Writes built_packages.json to the cwd: the final per-package publish
# manifest (distro/type/name/pkgbase/build_status/job_url/artifact_dir/
# filename/sha256 — the last two only set for packages that actually got
# signed and uploaded this run, null otherwise).
#
# Also stages a copy of every such package's file under ./attest-artifacts/
# (relative to the job workspace, i.e. actually on the host runner, not
# just inside this script's container — see below) so the calling
# workflow's own step, immediately after this script exits, can hand them
# to `actions/attest-build-provenance` and get GitHub to sign a build
# provenance attestation for the exact bytes just published. That has to
# happen as a real workflow step, not from in here: it needs the runner's
# own OIDC token to talk to Sigstore/GitHub's attestation API, which this
# script (running inside a throwaway `docker run --rm` archlinux container,
# with no such credential) has no access to and shouldn't need to.

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

retry pacman -Sy --noconfirm --needed curl jq

retry curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors \
  https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc

# Never trace the decoded private key material itself.
set +x
echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --batch --import
set -x
GPG_KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}')"
export GPG_KEY_ID

repo_name="${REPO_NAME:-akaere}"
keep_versions="${KEEP_VERSIONS:-1}"
alias_name="akaere-minio"

source build-kit/scripts/publish/repo_lib.sh
mc_alias_set

root_dir="$(pwd)"

# Read every manifest up front so packages can be grouped by distro before
# touching R2 at all — the bucket is laid out <distro>/x86_64/..., so each
# distro present in this batch (currently only ever "archlinux", but the
# schema allows more) gets its own wholly separate db and its own single
# download/upload cycle.
declare -A entry_distro entry_type entry_pkgbase entry_job_url entry_dir entry_status entry_filename entry_sha256
names=()

# Bind-mounted into the container at /workspace (see build-publish.yml),
# so anything written here is still there on the host runner once this
# script's `docker run --rm` exits — unlike a package's actual build/sign
# work_dir below, which is a plain `mktemp -d` INSIDE the container and
# disappears with it.
attest_dir="$(pwd)/attest-artifacts"
mkdir -p "$attest_dir"

for dir in artifacts/build-*/; do
  manifest="${dir}manifest.json"
  [[ -f "$manifest" ]] || continue
  name=$(jq -r .name "$manifest")
  names+=("$name")
  entry_distro[$name]=$(jq -r .distro "$manifest")
  entry_type[$name]=$(jq -r .type "$manifest")
  entry_pkgbase[$name]=$(jq -r .pkgbase "$manifest")
  entry_job_url[$name]=$(jq -r .job_url "$manifest")
  entry_dir[$name]="$root_dir/$dir"
  outcome=$(jq -r .build_outcome "$manifest")
  if [[ "$outcome" == "built" ]]; then
    # Resolved to published/publish_failed once its distro's db upload
    # (below) has actually been attempted — never left as "staged".
    entry_status[$name]="staged"
  else
    entry_status[$name]="build_failed"
  fi
done

# Distros to process come from the Registry checkout itself (path
# "registry/", see build-publish.yml), not from this run's staged names —
# a push that only DELETES packages stages nothing to build, but its
# distro's db still needs reconciling below. (A distro whose very last
# package is removed in one push has no directory left here to discover at
# all; out of scope for now — there's exactly one distro today and
# emptying it entirely in one push isn't a realistic case yet.)
distros=()
for d in registry/*/; do
  [[ -d "$d" ]] || continue
  distros+=("$(basename "$d")")
done

bucket="${R2_BUCKET:?R2_BUCKET required}"

for distro in "${distros[@]:-}"; do
  [[ -z "$distro" ]] && continue
  remote="${alias_name}/${bucket}/${distro}/x86_64"
  db_file="${repo_name}.db.tar.gz"
  files_file="${repo_name}.files.tar.gz"

  work_dir="$(mktemp -d)"
  cd "$work_dir"

  # An empty repository has neither metadata object. Anything else —
  # including a transient R2 failure, bad credentials, or only one object
  # being absent — must stop before repo-add could overwrite the existing
  # package index. A real failure here aborts the whole run (set -e): with
  # no reliable base db for this distro, nothing in the batch can safely
  # proceed for it.
  download_metadata_pair

  # Reconcile: repo-remove (+ delete from R2) anything still in the db
  # whose Registry entry is gone, using the CURRENT Registry tree for this
  # distro as the desired set — not this run's diff — so it self-heals any
  # prior gap, not just a removal from this specific push. See
  # prune_removed_packages in repo_lib.sh for the full rationale and its
  # empty-desired-list safety guard.
  desired_names="$(
    shopt -s nullglob
    for toml in "$root_dir/registry/$distro"/*/*/*.toml; do
      basename "$toml" .toml
    done
  )"
  any_pruned=false
  prune_removed_packages "$desired_names"

  any_staged=false
  for name in "${names[@]:-}"; do
    [[ -z "$name" ]] && continue
    [[ "${entry_status[$name]}" == "staged" && "${entry_distro[$name]}" == "$distro" ]] || continue
    any_staged=true
    # Safe as a plain glob: package.sh already narrowed the artifact
    # directory down to exactly the one file this Registry entry tracks —
    # no other package's files ever land in the same directory. Not
    # anchored to -x86_64.pkg.tar.zst specifically: an arch=(any) package
    # (fonts, pure-data packages) produces .../<pkgrel>-any.pkg.tar.zst.
    pkg_file=$(find "${entry_dir[$name]}" -maxdepth 1 -name "${name}-*.pkg.tar.zst" | head -n1)
    if [[ -z "$pkg_file" ]]; then
      entry_status[$name]="publish_failed"
      echo "::error::no built package file found for $name in ${entry_dir[$name]}" >&2
      continue
    fi
    cp "$pkg_file" .
    pkg_basename="$(basename "$pkg_file")"
    sig_basename="${pkg_basename}.sig"
    if sign_and_add "$pkg_basename" && upload_package_file "$pkg_basename" "$sig_basename"; then
      entry_filename[$name]="$pkg_basename"
      entry_sha256[$name]="$(sha256sum "$pkg_basename" | awk '{print $1}')"
      cp "$pkg_basename" "$attest_dir/"
      : # left "staged" — resolved to published/publish_failed below, once
        # the one db upload for this distro has actually been attempted
    else
      entry_status[$name]="publish_failed"
      echo "::error::failed to sign/upload $name to R2" >&2
    fi
  done

  db_upload_ok=true
  if [[ "$any_staged" == true || "$any_pruned" == true ]]; then
    if upload_repo; then
      echo "published repo db for $distro"
      if ! upload_public_key; then
        echo "::warning::couldn't publish the public key file for $distro (packages are still published correctly; key distribution just isn't updated this run)" >&2
      fi
    else
      db_upload_ok=false
      echo "::error::final repository db upload failed for $distro — no staged package or removal in this batch actually landed in the published index" >&2
    fi
  fi

  for name in "${names[@]:-}"; do
    [[ -z "$name" ]] && continue
    [[ "${entry_status[$name]}" == "staged" && "${entry_distro[$name]}" == "$distro" ]] || continue
    if [[ "$db_upload_ok" == true ]]; then
      entry_status[$name]="published"
      prune_old_versions "$name" "$keep_versions"
    else
      entry_status[$name]="publish_failed"
    fi
  done

  cd "$root_dir"
  rm -rf "$work_dir"
done

final="[]"
for name in "${names[@]:-}"; do
  [[ -z "$name" ]] && continue
  entry=$(jq -n \
    --arg distro "${entry_distro[$name]}" --arg type "${entry_type[$name]}" --arg name "$name" \
    --arg pkgbase "${entry_pkgbase[$name]}" --arg status "${entry_status[$name]}" \
    --arg job_url "${entry_job_url[$name]}" --arg artifact_dir "artifacts/build-${name}/" \
    --arg filename "${entry_filename[$name]:-}" --arg sha256 "${entry_sha256[$name]:-}" \
    '{distro:$distro,type:$type,name:$name,pkgbase:$pkgbase,build_status:$status,job_url:$job_url,artifact_dir:$artifact_dir,
      filename:(if $filename == "" then null else $filename end),sha256:(if $sha256 == "" then null else $sha256 end)}')
  final=$(jq --argjson e "$entry" '. + [$e]' <<< "$final")
done
echo "$final" > "$root_dir/built_packages.json"
cat "$root_dir/built_packages.json"
