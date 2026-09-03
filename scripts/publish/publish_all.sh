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
# Must run from the job workspace root (the directory holding both
# `artifacts/` — this run's downloaded build-* artifacts — and `build-kit/`
# — this checkout of workflow-build-kit itself, for scripts/publish/minio.sh).
#
# Required env: R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#               GPG_PRIVATE_KEY (base64-encoded armored export)
# Optional env: GPG_PASSPHRASE (empty/unset if the signing key has none)
#
# Writes built_packages.json to the cwd: the final per-package publish
# manifest (distro/type/name/pkgbase/build_status/job_url/artifact_dir).

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

final="[]"
for dir in artifacts/build-*/; do
  manifest="$dir/manifest.json"
  [[ -f "$manifest" ]] || continue
  distro=$(jq -r .distro "$manifest")
  name=$(jq -r .name "$manifest")
  type=$(jq -r .type "$manifest")
  pkgbase=$(jq -r .pkgbase "$manifest")
  outcome=$(jq -r .build_outcome "$manifest")
  job_url=$(jq -r .job_url "$manifest")

  status="build_failed"
  if [[ "$outcome" == "built" ]]; then
    # Safe as a plain glob (unlike build/package.sh's own selection logic):
    # package.sh already narrowed $dir down to exactly the one file this
    # Registry entry tracks before it ever became this artifact — no other
    # package's files ever land in the same directory, so there's nothing
    # else here for the glob to accidentally match. Not anchored to
    # -x86_64.pkg.tar.zst specifically: an arch=(any) package (fonts,
    # pure-data packages) produces .../<pkgrel>-any.pkg.tar.zst instead.
    pkg_file=$(find "$dir" -maxdepth 1 -name "${name}-*.pkg.tar.zst" | head -n1)
    if [[ -n "$pkg_file" ]] && DISTRO="$distro" bash build-kit/scripts/publish/minio.sh "$name" "$pkg_file"; then
      status="published"
    else
      status="publish_failed"
      echo "::error::failed to publish $name to R2"
    fi
  fi

  entry=$(jq -n \
    --arg distro "$distro" --arg type "$type" --arg name "$name" --arg pkgbase "$pkgbase" \
    --arg status "$status" --arg job_url "$job_url" --arg artifact_dir "$dir" \
    '{distro:$distro,type:$type,name:$name,pkgbase:$pkgbase,build_status:$status,job_url:$job_url,artifact_dir:$artifact_dir}')
  final=$(jq --argjson e "$entry" '. + [$e]' <<< "$final")
done
echo "$final" > built_packages.json
cat built_packages.json
