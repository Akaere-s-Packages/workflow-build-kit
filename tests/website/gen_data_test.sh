#!/usr/bin/env bash
set -euo pipefail

# Self-contained tests for gen_data.sh (a fake backends/testdistro, no
# network) — covers what the old tests/website/test_gen_data.py's
# BuildDetailTests/FetchSourcesTests classes intended to (a pre-existing
# bug in that file — `if __name__ == "__main__": unittest.main()`
# appeared BEFORE those two classes were even defined, so neither ever
# actually ran; only ParseSourcesTests did). ParseSourcesTests' own intent
# is covered separately and far more thoroughly by
# backends/archlinux/fetch-sources.sh's differential tests against real
# AUR data (done during that script's own development, not repeated
# here).
#
# Exercises: sources refresh-from-pkgbase, existing sources preserved
# when the sources backend fails, and the published/build_failed merge
# paths end to end.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_backend() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/fetch-info.sh" <<'FI'
#!/usr/bin/env bash
set -euo pipefail
names_json="$(cat)"
jq -n --argjson names "$names_json" '
  {
    "pkg-ok": {version: "1.1-1", depends: [], description: "ok package", url: "https://example.com/pkg-ok",
               license: ["MIT"], maintainer: "alice", submitter: "alice", votes: 5, popularity: 1.5,
               first_submitted: "2020-01-01T00:00:00Z"},
    "pkg-fail-src": {version: "2.0-1", depends: [], description: "fail-src package", url: null,
                      license: [], maintainer: null, submitter: null, votes: null, popularity: null,
                      first_submitted: null},
    "pkg-built": {version: "3.0-1", depends: [], description: "built package", url: null,
                  license: [], maintainer: "bob", submitter: "bob", votes: 1, popularity: 0.1,
                  first_submitted: null},
    "pkg-failed-build": {version: "4.0-1", depends: [], description: null, url: null,
                          license: [], maintainer: null, submitter: null, votes: null, popularity: null,
                          first_submitted: null}
  } as $all
  | $names | map(select(. as $n | $all | has($n))) | map({(.): $all[.]}) | add // {}
'
FI

  cat > "$dir/fetch-sources.sh" <<'FS'
#!/usr/bin/env bash
set -euo pipefail
pkgbase="${1:?pkgbase required}"
case "$pkgbase" in
  pkg-ok)
    jq -n '[{name: "release.tar.gz", url: "https://example.test/release.tar.gz"}]'
    ;;
  pkg-fail-src)
    echo "simulated fetch failure" >&2
    exit 1
    ;;
  *)
    jq -n '[]'
    ;;
esac
FS

  chmod +x "$dir/fetch-info.sh" "$dir/fetch-sources.sh"
}

setup_repo_tree() {
  local tmp="$1"
  mkdir -p "$tmp/build-kit/scripts/website" "$tmp/build-kit/scripts/registry" "$tmp/build-kit/scripts/lib" \
           "$tmp/build-kit/backends/testdistro"
  cp "$repo_root/scripts/website/gen_data.sh" "$tmp/build-kit/scripts/website/"
  cp "$repo_root/scripts/registry/load_registry.sh" "$tmp/build-kit/scripts/registry/"
  cp "$repo_root/scripts/lib/toml.sh" "$tmp/build-kit/scripts/lib/"
  chmod +x "$tmp/build-kit/scripts/website/gen_data.sh" "$tmp/build-kit/scripts/registry/load_registry.sh"
  make_fake_backend "$tmp/build-kit/backends/testdistro"
}

make_registry() {
  local tmp="$1" reg="$tmp/registry"
  mkdir -p "$reg/testdistro/aur/pkg-ok" "$reg/testdistro/aur/pkg-fail-src" \
           "$reg/testdistro/aur/pkg-built" "$reg/testdistro/aur/pkg-failed-build"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-ok"' 'version = "1.0-1"' 'autoupdate = true' > "$reg/testdistro/aur/pkg-ok/pkg-ok.toml"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-fail-src"' 'version = "2.0-1"' 'autoupdate = false' > "$reg/testdistro/aur/pkg-fail-src/pkg-fail-src.toml"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-built"' 'version = "3.0-1"' 'autoupdate = false' > "$reg/testdistro/aur/pkg-built/pkg-built.toml"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-failed-build"' 'version = "4.0-1"' 'autoupdate = false' > "$reg/testdistro/aur/pkg-failed-build/pkg-failed-build.toml"
  git -C "$reg" init -q -b main
  git -C "$reg" config user.email test@example.com
  git -C "$reg" config user.name test
  git -C "$reg" add -A
  git -C "$reg" commit -q -m base
}

test_gen_data_end_to_end() {
  local tmp; tmp="$(mktemp -d)"
  setup_repo_tree "$tmp"
  make_registry "$tmp"

  local data_dir="$tmp/website_data"
  mkdir -p "$data_dir/packageDetails"

  # Pre-existing packageDetails for pkg-fail-src: a stale sources list
  # that must be PRESERVED since this run's sources fetch fails for it.
  jq -n '{name:"pkg-fail-src", sources:[{name:"stale.tar.gz", url:"https://old.example/stale.tar.gz"}], files:[], build_status:"unknown"}' \
    > "$data_dir/packageDetails/pkg-fail-src.json"

  # Pre-existing packageDetails for pkg-failed-build: a previously
  # published state that must survive this run's build_failed status
  # untouched (version/files/filename/sha256 stay as they were, except
  # filename/sha256 explicitly nulled since a failed build is never
  # trusted as "this is definitely still the live file").
  jq -n '{name:"pkg-failed-build", version:"3.9-1", files:[{path:"/usr/bin/old", size_bytes:42}],
          package_size_bytes:42, filename:"pkg-failed-build-3.9-1-x86_64.pkg.tar.zst", sha256:"deadbeef",
          build_status:"published", last_updated:"2020-06-01T00:00:00Z"}' \
    > "$data_dir/packageDetails/pkg-failed-build.json"

  # Build artifacts for pkg-built (published this run).
  mkdir -p "$tmp/artifacts/pkg-built"
  jq -n '{package_size_bytes: 300, files: [{path:"/usr/bin/pkg-built", size_bytes:300}]}' \
    > "$tmp/artifacts/pkg-built/file_list.json"
  jq -n '{description:"built desc", url:"https://example.com/built", licenses:["GPL-3.0"],
          packager:"Test <t@example.com>", dependencies:[{name:"glibc",type:"depends",repo:"core"}]}' \
    > "$tmp/artifacts/pkg-built/build_meta.json"

  jq -n --arg dir "$tmp/artifacts/pkg-built" '[
    {type:"aur", name:"pkg-built", pkgbase:"pkg-built", build_status:"published",
     job_url:"https://example.com/pkg-built", artifact_dir:$dir,
     filename:"pkg-built-3.0-1-x86_64.pkg.tar.zst", sha256:"cafef00d"},
    {type:"aur", name:"pkg-failed-build", pkgbase:"pkg-failed-build", build_status:"build_failed",
     job_url:"https://example.com/pkg-failed-build", artifact_dir:"", filename:null, sha256:null}
  ]' > "$tmp/built.json"

  (
    cd "$tmp/registry"
    "$tmp/build-kit/scripts/website/gen_data.sh" \
      --registry-root . --website-data-dir "$data_dir" --built "$tmp/built.json"
  ) > "$tmp/output.log" 2>&1 || fail "gen_data.sh failed: $(cat "$tmp/output.log")"

  # --- pkg-ok: fresh sources, AUR fields refreshed, never built -> build_status unknown ---
  local ok_detail; ok_detail="$(cat "$data_dir/packageDetails/pkg-ok.json")"
  [[ "$(jq -c '.sources' <<<"$ok_detail")" == '[{"name":"release.tar.gz","url":"https://example.test/release.tar.gz"}]' ]] \
    || fail "pkg-ok sources: $ok_detail"
  [[ "$(jq -r '.maintainer' <<<"$ok_detail")" == "alice" ]] || fail "pkg-ok maintainer: $ok_detail"
  [[ "$(jq -r '.build_status' <<<"$ok_detail")" == "unknown" ]] || fail "pkg-ok build_status: $ok_detail"
  [[ "$(jq -r '.version' <<<"$ok_detail")" == "1.0-1" ]] || fail "pkg-ok version should stay Registry's, not upstream's: $ok_detail"

  # --- pkg-fail-src: sources fetch failed -> existing (stale) sources preserved untouched ---
  local fail_src_detail; fail_src_detail="$(cat "$data_dir/packageDetails/pkg-fail-src.json")"
  [[ "$(jq -c '.sources' <<<"$fail_src_detail")" == '[{"name":"stale.tar.gz","url":"https://old.example/stale.tar.gz"}]' ]] \
    || fail "pkg-fail-src sources should be preserved: $fail_src_detail"

  # --- pkg-built: published this run -> full refresh from build_meta/file_list ---
  local built_detail; built_detail="$(cat "$data_dir/packageDetails/pkg-built.json")"
  [[ "$(jq -r '.build_status' <<<"$built_detail")" == "published" ]] || fail "pkg-built status: $built_detail"
  [[ "$(jq -r '.filename' <<<"$built_detail")" == "pkg-built-3.0-1-x86_64.pkg.tar.zst" ]] || fail "pkg-built filename: $built_detail"
  [[ "$(jq -r '.sha256' <<<"$built_detail")" == "cafef00d" ]] || fail "pkg-built sha256: $built_detail"
  [[ "$(jq -r '.package_size_bytes' <<<"$built_detail")" == "300" ]] || fail "pkg-built size: $built_detail"
  [[ "$(jq -r '.packager' <<<"$built_detail")" == "Test <t@example.com>" ]] || fail "pkg-built packager: $built_detail"
  [[ "$(jq -r '.description' <<<"$built_detail")" == "built desc" ]] || fail "pkg-built description (build_meta wins over AUR): $built_detail"
  [[ "$(jq -r '.last_updated' <<<"$built_detail")" != "null" ]] || fail "pkg-built last_updated should be set: $built_detail"

  # --- pkg-failed-build: build_failed this run -> old version/files/size kept,
  # filename/sha256 explicitly nulled (a failed build's file is never
  # trusted as still being the live one) ---
  local failed_detail; failed_detail="$(cat "$data_dir/packageDetails/pkg-failed-build.json")"
  [[ "$(jq -r '.build_status' <<<"$failed_detail")" == "build_failed" ]] || fail "pkg-failed-build status: $failed_detail"
  [[ "$(jq -r '.version' <<<"$failed_detail")" == "3.9-1" ]] || fail "pkg-failed-build version should be kept: $failed_detail"
  [[ "$(jq -r '.filename' <<<"$failed_detail")" == "null" ]] || fail "pkg-failed-build filename must be nulled: $failed_detail"
  [[ "$(jq -r '.sha256' <<<"$failed_detail")" == "null" ]] || fail "pkg-failed-build sha256 must be nulled: $failed_detail"
  [[ "$(jq -r '.last_updated' <<<"$failed_detail")" == "2020-06-01T00:00:00Z" ]] || fail "pkg-failed-build last_updated should be kept: $failed_detail"
  [[ "$(jq -r '.package_size_bytes' <<<"$failed_detail")" == "42" ]] || fail "pkg-failed-build size should be kept: $failed_detail"

  # --- packages.json / stats.json sanity ---
  [[ "$(jq 'length' "$data_dir/packages.json")" == "4" ]] || fail "packages.json should list all 4 packages"
  [[ "$(jq '.packages' "$data_dir/stats.json")" == "4" ]] || fail "stats.json packages count"
  # pkg-ok (never built) and pkg-fail-src (seeded above with
  # build_status:"unknown", and never in this run's built.json either)
  # both count.
  [[ "$(jq '.never_updated' "$data_dir/stats.json")" == "2" ]] || fail "stats.json never_updated should count pkg-ok and pkg-fail-src: $(jq . "$data_dir/stats.json")"

  rm -rf "$tmp"
  echo "PASS: test_gen_data_end_to_end"
}

test_gen_data_end_to_end
echo "gen_data.sh tests passed"
