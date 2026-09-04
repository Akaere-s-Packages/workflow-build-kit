#!/usr/bin/env bash
set -euo pipefail

# Exercises publish_all.sh's batched path: sign+repo-add every built
# package into ONE local db per distro, upload that db exactly once (not
# once per package), and correctly resolve every staged package's status
# only after that one upload has actually been attempted.
#
# Runs the real gpg/repo-add/bsdtar/vercmp on this machine (a throwaway
# GNUPGHOME, never the real keyring) against a fake `mc` that just logs
# calls — no real R2 credentials or network access needed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

make_pkg() {
  local tmp="$1" name="$2" ver="$3" rel="$4"
  local dir="$tmp/artifacts/build-$name"
  mkdir -p "$dir"
  local pkgroot="$tmp/pkgroot-$name"
  mkdir -p "$pkgroot"
  cat > "$pkgroot/.PKGINFO" <<EOF
pkgname = $name
pkgbase = $name
pkgver = $ver-$rel
pkgdesc = test
arch = x86_64
license = MIT
EOF
  ( cd "$pkgroot" && bsdtar -cf - .PKGINFO | zstd -q -o "$dir/${name}-${ver}-${rel}-x86_64.pkg.tar.zst" )
  cat > "$dir/manifest.json" <<EOF
{"distro":"archlinux","type":"aur","name":"$name","pkgbase":"$name","build_outcome":"built","job_url":"https://example/$name"}
EOF
}

make_build_failed() {
  local tmp="$1" name="$2"
  mkdir -p "$tmp/artifacts/build-$name"
  cat > "$tmp/artifacts/build-$name/manifest.json" <<EOF
{"distro":"archlinux","type":"aur","name":"$name","pkgbase":"$name","build_outcome":"build_failed","job_url":"https://example/$name"}
EOF
}

# publish_all.sh now discovers which distros to process (and, per distro,
# which pkgnames are allowed to stay in the db) from a "registry/" checkout
# in the job workspace, not just from this run's staged packages — every
# package under test needs a matching toml here or it's invisible to that
# discovery.
make_registry_entry() {
  local tmp="$1" name="$2"
  mkdir -p "$tmp/registry/archlinux/aur/$name"
  printf '%s\n' '[PACKAGES]' "name = \"$name\"" > "$tmp/registry/archlinux/aur/$name/$name.toml"
}

# mode: "ok" (every mc call succeeds, once the metadata bootstrap 404 is
# past) or "db-upload-fails" (the final akaere.db.tar.gz upload always
# fails, everything else succeeds).
run_batch() {
  local tmp="$1" mode="$2"

  cat > "$tmp/bin/mc" <<MC
#!/usr/bin/env bash
set -euo pipefail
log="\${MC_LOG:?}"
cmd="\$1"; shift
echo "mc \$cmd \$*" >> "\$log"
case "\$cmd" in
  alias) exit 0 ;;
  cp)
    src="\$1"; dst="\$2"
    if [[ "\$dst" == "." ]]; then
      # A seeded object under seed/ simulates a package already published
      # (from some earlier run) before this batch even starts — used by
      # the prune-reconciliation test below. Everything else keeps
      # simulating the first-ever-publish "object does not exist" 404 the
      # other tests rely on.
      seeded="$tmp/seed/\$(basename "\$src")"
      if [[ -f "\$seeded" ]]; then
        cp "\$seeded" .
        exit 0
      fi
      echo "mc: <ERROR> Unable to prepare URL for copying. Object does not exist" >&2
      exit 1
    fi
    if [[ "$mode" == "db-upload-fails" && "\$src" == akaere.db.tar.gz && "\$dst" == */akaere.db.tar.gz ]]; then
      echo "mc: <ERROR> simulated R2 failure" >&2
      exit 1
    fi
    exit 0
    ;;
  ls) [[ -f "$tmp/seed/ls_output.txt" ]] && cat "$tmp/seed/ls_output.txt"; exit 0 ;;
  rm) exit 0 ;;
esac
MC
  chmod +x "$tmp/bin/mc"

  (
    cd "$tmp"
    export PATH="$tmp/bin:$PATH"
    export MC_LOG="$tmp/mc.log"
    export R2_ENDPOINT=https://example.r2.cloudflarestorage.com
    export R2_ACCESS_KEY_ID=id R2_SECRET_ACCESS_KEY=secret R2_BUCKET=bucket
    export GNUPGHOME="$tmp/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
      --quick-generate-key 'Test <test@example.com>' default default 0 >/dev/null 2>&1
    GPG_KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}')"
    export GPG_KEY_ID GPG_PASSPHRASE=""

    mkdir -p build-kit/scripts/publish build-kit/backends/archlinux
    cp "$repo_root/scripts/publish/repo_lib.sh" build-kit/scripts/publish/
    cp "$repo_root/backends/archlinux/repo_lib.sh" build-kit/backends/archlinux/
    sed -n '/^repo_name=/,$p' "$repo_root/scripts/publish/publish_all.sh" > batch_only.sh
    bash batch_only.sh > run.log 2>&1
  )
}

test_batch_success() {
  local tmp
  tmp="$(mktemp -d)"
  make_pkg "$tmp" pkga 1.0 1
  make_pkg "$tmp" pkgb 2.0 1
  make_pkg "$tmp" pkgc 3.0 1
  make_build_failed "$tmp" pkgd
  make_registry_entry "$tmp" pkga
  make_registry_entry "$tmp" pkgb
  make_registry_entry "$tmp" pkgc
  make_registry_entry "$tmp" pkgd
  mkdir -p "$tmp/bin"

  run_batch "$tmp" ok

  local statuses
  statuses="$(jq -r '.[] | "\(.name)=\(.build_status)"' "$tmp/built_packages.json" | sort)"
  assert_eq $'pkga=published\npkgb=published\npkgc=published\npkgd=build_failed' "$statuses"

  # The six db-related objects must each appear exactly once, no matter
  # how many packages were in the batch — that's the entire point of this
  # refactor (previously: once per successfully-published package).
  local db_upload_count
  db_upload_count="$(grep -cE 'mc cp akaere\.(db|files)\.tar\.gz(\.sig)? akaere-minio/' "$tmp/mc.log")"
  assert_eq 6 "$db_upload_count"

  local per_pkg_upload_count
  per_pkg_upload_count="$(grep -cE 'mc cp pkg[a-c]-[0-9.]+-1-x86_64\.pkg\.tar\.zst pkg[a-c]-[0-9.]+-1-x86_64\.pkg\.tar\.zst\.sig ' "$tmp/mc.log")"
  assert_eq 3 "$per_pkg_upload_count"

  rm -rf "$tmp"
  echo "PASS: test_batch_success"
}

test_db_upload_failure_marks_everything_publish_failed() {
  local tmp
  tmp="$(mktemp -d)"
  make_pkg "$tmp" pkga 1.0 1
  make_pkg "$tmp" pkgb 2.0 1
  make_registry_entry "$tmp" pkga
  make_registry_entry "$tmp" pkgb
  mkdir -p "$tmp/bin"

  run_batch "$tmp" db-upload-fails

  local statuses
  statuses="$(jq -r '.[] | "\(.name)=\(.build_status)"' "$tmp/built_packages.json" | sort)"
  # Both packages signed and repo-add'd cleanly, and even uploaded their
  # own file+sig successfully — but the ONE shared db upload for the whole
  # batch failed, so neither is actually discoverable via the published
  # index yet. A regression here (only marking the last-processed package
  # as failed) is exactly the bug this test was written to catch: it was
  # caused by sign_and_add/upload_repo being called as `if` conditions,
  # which makes bash's `set -e` ignore failures inside their own bodies
  # unless each step's exit status is checked explicitly.
  assert_eq $'pkga=publish_failed\npkgb=publish_failed' "$statuses"

  rm -rf "$tmp"
  echo "PASS: test_db_upload_failure_marks_everything_publish_failed"
}

test_prune_removes_deregistered_package() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/seed"

  # Seed a db that already has "pkgold" published (as if from an earlier
  # run) — the Registry checkout this run only lists "pkgnew", so pkgold
  # is a package whose toml is gone. No -s/-k here: the seed db's own
  # signature is never checked by anything under test, only its content.
  local seedroot="$tmp/seedroot"
  mkdir -p "$seedroot/pkgroot"
  cat > "$seedroot/pkgroot/.PKGINFO" <<EOF
pkgname = pkgold
pkgbase = pkgold
pkgver = 1.0-1
pkgdesc = test
arch = x86_64
license = MIT
EOF
  ( cd "$seedroot/pkgroot" && bsdtar -cf - .PKGINFO | zstd -q -o "../pkgold-1.0-1-x86_64.pkg.tar.zst" )
  ( cd "$seedroot" && repo-add akaere.db.tar.gz pkgold-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
  cp "$seedroot/akaere.db.tar.gz" "$seedroot/akaere.files.tar.gz" "$tmp/seed/"
  # mc ls output is just each object's bare basename, matching how the
  # real `mc ls <prefix>/` — and prune_old_versions' own parsing of it —
  # already behaves.
  printf '%s\n' \
    'pkgold-1.0-1-x86_64.pkg.tar.zst' \
    'pkgold-1.0-1-x86_64.pkg.tar.zst.sig' \
    > "$tmp/seed/ls_output.txt"

  make_pkg "$tmp" pkgnew 1.0 1
  make_registry_entry "$tmp" pkgnew   # pkgold deliberately NOT registered

  run_batch "$tmp" ok

  grep -qE '^mc rm akaere-minio/bucket/archlinux/x86_64/pkgold-1\.0-1-x86_64\.pkg\.tar\.zst akaere-minio/bucket/archlinux/x86_64/pkgold-1\.0-1-x86_64\.pkg\.tar\.zst\.sig$' "$tmp/mc.log" \
    || fail "expected pkgold's package + sig to be removed from R2; mc.log:"$'\n'"$(cat "$tmp/mc.log")"

  local statuses
  statuses="$(jq -r '.[] | "\(.name)=\(.build_status)"' "$tmp/built_packages.json" | sort)"
  assert_eq "pkgnew=published" "$statuses"

  rm -rf "$tmp"
  echo "PASS: test_prune_removes_deregistered_package"
}

test_batch_success
test_db_upload_failure_marks_everything_publish_failed
test_prune_removes_deregistered_package
echo "publish_all batching tests passed"
