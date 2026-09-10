#!/usr/bin/env bash
set -euo pipefail

# Integration test for remove_package.sh: real git (against a local bare
# "origin"), a fake `gh`, and a fake backends/testdistro/fetch-info.sh —
# no network, no real AUR.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

make_fake_gh() {
  local bin_dir="$1"
  cat > "$bin_dir/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "${GH_LOG:?}"

case "$1 $2" in
  "pr list")
    branch=""
    for ((i=1; i<=$#; i++)); do
      if [[ "${!i}" == "--head" ]]; then j=$((i+1)); branch="${!j}"; fi
    done
    fixture="${GH_FIXTURES:?}/pr_list_${branch//\//_}.json"
    [[ -f "$fixture" ]] && cat "$fixture" || echo "[]"
    ;;
  "pr create")
    title="" head="" body=""
    for ((i=1; i<=$#; i++)); do
      case "${!i}" in
        --title) j=$((i+1)); title="${!j}" ;;
        --head) j=$((i+1)); head="${!j}" ;;
        --body) j=$((i+1)); body="${!j}" ;;
      esac
    done
    echo "CREATE head=$head title=$title" >> "${GH_CALLS:?}"
    printf '%s\n' "$body" > "${GH_BODY:?}"
    echo "https://github.com/fake/fake/pull/7"
    ;;
  *)
    echo "unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
GH
  chmod +x "$bin_dir/gh"
}

make_fake_backend() {
  local dir="$1"
  mkdir -p "$dir"

  # Deliberately mirrors the two dependency shapes the real Registry
  # has: `app` -> `lib` known only from upstream's own depends (the
  # common case — hand-authored TOMLs almost never carry aur_depends),
  # and `rec-parent` -> `rec-child` known only from the Registry's
  # recorded aur_depends (what add_package.sh writes).
  cat > "$dir/fetch-info.sh" <<'FI'
#!/usr/bin/env bash
set -euo pipefail
names_json="$(cat)"
if [[ "${FETCH_INFO_EMPTY:-}" == "1" ]]; then
  echo '{}'
  exit 0
fi
jq -n --argjson names "$names_json" '
  {
    "leaf": {version: "1.0-1", pkgbase: "leaf", depends: ["some-official-lib"]},
    "app": {version: "2.0-1", pkgbase: "app", depends: ["lib"]},
    "lib": {version: "0.5-1", pkgbase: "lib", depends: []},
    "rec-parent": {version: "3.0-1", pkgbase: "rec-parent", depends: []},
    "rec-child": {version: "0.9-1", pkgbase: "rec-child", depends: []}
  } as $all
  | $names | map(select(. as $n | $all | has($n))) | map({(.): $all[.]}) | add // {}
'
FI
  chmod +x "$dir/fetch-info.sh"
}

setup_repo_tree() {
  local tmp="$1"
  mkdir -p "$tmp/build-kit/scripts/update" "$tmp/build-kit/scripts/registry" "$tmp/build-kit/scripts/lib" \
           "$tmp/build-kit/tools/depgraph" "$tmp/build-kit/backends/testdistro"
  cp "$repo_root/scripts/update/remove_package.sh" "$tmp/build-kit/scripts/update/"
  cp "$repo_root/scripts/registry/load_registry.sh" "$tmp/build-kit/scripts/registry/"
  cp "$repo_root/scripts/lib/toml.sh" "$repo_root/scripts/lib/run.sh" "$tmp/build-kit/scripts/lib/"
  cp "$repo_root/tools/depgraph/depgraph" "$tmp/build-kit/tools/depgraph/"
  chmod +x "$tmp/build-kit/scripts/update/remove_package.sh" "$tmp/build-kit/scripts/registry/load_registry.sh" \
    "$tmp/build-kit/tools/depgraph/depgraph"
  make_fake_backend "$tmp/build-kit/backends/testdistro"
}

write_toml() {
  local reg="$1" name="$2" version="$3" extra="${4:-}"
  mkdir -p "$reg/testdistro/aur/$name"
  {
    echo '[PACKAGES]'
    echo "name = \"$name\""
    echo "version = \"$version\""
    echo 'autoupdate = true'
    [[ -n "$extra" ]] && echo "$extra"
  } > "$reg/testdistro/aur/$name/$name.toml"
}

make_registry_repo() {
  local tmp="$1" reg="$tmp/registry"
  write_toml "$reg" leaf "1.0-1"
  write_toml "$reg" app "2.0-1"
  write_toml "$reg" lib "0.5-1"
  write_toml "$reg" rec-parent "3.0-1" 'aur_depends = ["rec-child"]'
  write_toml "$reg" rec-child "0.9-1"
  # Deliberately unknown to the fake backend, with no recorded
  # aur_depends either — the real Registry has exactly this
  # (rog-control-center, a split pkgname AUR RPC doesn't index).
  write_toml "$reg" ghost "1.2-1"

  git -C "$reg" init -q -b main
  git -C "$reg" config user.email test@example.com
  git -C "$reg" config user.name test
  git -C "$reg" add -A
  git -C "$reg" commit -q -m base

  git init -q --bare "$tmp/origin.git"
  git -C "$reg" remote add origin "$tmp/origin.git"
  git -C "$reg" push -q origin main
}

run_remove_package() {
  local tmp="$1"; shift
  (
    cd "$tmp/registry"
    export PATH="$tmp/bin:$PATH"
    export GH_FIXTURES="$tmp/fixtures"
    export GH_LOG="$tmp/gh.log"
    export GH_CALLS="$tmp/gh_calls.log"
    export GH_BODY="$tmp/pr_body.txt"
    export GH_TOKEN=fake
    export FETCH_INFO_EMPTY="${FETCH_INFO_EMPTY:-}"
    : >> "$GH_CALLS"
    "$tmp/build-kit/scripts/update/remove_package.sh" --registry-root . "$@"
  )
}

setup_common() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/fixtures"
  make_fake_gh "$tmp/bin"
  setup_repo_tree "$tmp"
  make_registry_repo "$tmp"
  echo "$tmp"
}

test_removes_a_leaf_package() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package leaf > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "removing 1 package" "$tmp/output.log" || fail "expected 1 package: $(cat "$tmp/output.log")"

  local branch="remove/leaf"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch on origin"
  git -C "$tmp/origin.git" show "$branch:testdistro/aur/leaf/leaf.toml" >/dev/null 2>&1 \
    && fail "leaf.toml should be gone on $branch"
  git -C "$tmp/origin.git" show "$branch:testdistro/aur/app/app.toml" >/dev/null 2>&1 \
    || fail "unrelated packages must be left alone"

  assert_eq "leaf: remove 1.0-1" "$(git -C "$tmp/origin.git" log --format=%s main.."$branch")"
  grep -q "CREATE head=$branch title=remove leaf$" "$tmp/gh_calls.log" || fail "unexpected PR create: $(cat "$tmp/gh_calls.log")"

  # The working tree is left back on main with no leftover local branch.
  assert_eq main "$(git -C "$tmp/registry" rev-parse --abbrev-ref HEAD)"
  [[ -f "$tmp/registry/testdistro/aur/leaf/leaf.toml" ]] || fail "main's own copy should be untouched"

  rm -rf "$tmp"
  echo "PASS: test_removes_a_leaf_package"
}

test_refuses_when_upstream_dependent_still_tracked() {
  local tmp; tmp="$(setup_common)"

  set +e
  run_remove_package "$tmp" --package lib > "$tmp/output.log" 2>&1
  local status=$?
  set -e
  [[ $status -ne 0 ]] || fail "expected a nonzero exit when a tracked package still depends on the target"
  grep -q "app -> lib" "$tmp/output.log" || fail "expected the blocking dependent in the error: $(cat "$tmp/output.log")"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have created a PR"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/remove/lib" && fail "should not have pushed a branch"

  rm -rf "$tmp"
  echo "PASS: test_refuses_when_upstream_dependent_still_tracked"
}

test_refuses_on_recorded_aur_depends_only() {
  local tmp; tmp="$(setup_common)"

  # rec-parent's dependency on rec-child exists ONLY in the Registry's
  # own aur_depends field — the fake backend reports no depends for it at
  # all. Checking upstream alone would happily delete rec-child here and
  # break rec-parent's next chain build.
  set +e
  run_remove_package "$tmp" --package rec-child > "$tmp/output.log" 2>&1
  local status=$?
  set -e
  [[ $status -ne 0 ]] || fail "expected a nonzero exit for a dependency recorded only in aur_depends"
  grep -q "rec-parent -> rec-child" "$tmp/output.log" || fail "expected the recorded dependent in the error: $(cat "$tmp/output.log")"

  rm -rf "$tmp"
  echo "PASS: test_refuses_on_recorded_aur_depends_only"
}

test_removes_dependent_and_dependency_together() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package "app, lib" > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "removing 2 package" "$tmp/output.log" || fail "expected 2 packages: $(cat "$tmp/output.log")"

  local branch="remove/app+lib"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch on origin"

  # Dependent dropped BEFORE its dependency — the reverse of the order
  # they'd have been added in. git log lists newest first.
  assert_eq $'lib: remove 0.5-1\napp: remove 2.0-1' "$(git -C "$tmp/origin.git" log --format=%s main.."$branch")"
  for name in app lib; do
    git -C "$tmp/origin.git" show "$branch:testdistro/aur/$name/$name.toml" >/dev/null 2>&1 \
      && fail "$name.toml should be gone on $branch"
  done

  rm -rf "$tmp"
  echo "PASS: test_removes_dependent_and_dependency_together"
}

test_orphaned_dependency_is_reported_not_removed() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package app > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"

  local branch="remove/app"
  git -C "$tmp/origin.git" show "$branch:testdistro/aur/lib/lib.toml" >/dev/null 2>&1 \
    || fail "lib was only depended on by app, but must NOT be removed automatically"
  grep -q "nothing tracked will depend on these anymore: lib" "$tmp/output.log" \
    || fail "expected the orphan note: $(cat "$tmp/output.log")"
  grep -q '`lib`' "$tmp/pr_body.txt" || fail "expected lib mentioned in the PR body: $(cat "$tmp/pr_body.txt")"

  rm -rf "$tmp"
  echo "PASS: test_orphaned_dependency_is_reported_not_removed"
}

test_unknown_package_is_reported_as_unchecked() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package leaf > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "NOT checked .*: ghost" "$tmp/output.log" \
    || fail "expected a warning that ghost couldn't be checked: $(cat "$tmp/output.log")"
  grep -q "Not checked" "$tmp/pr_body.txt" || fail "expected the unchecked note in the PR body: $(cat "$tmp/pr_body.txt")"
  grep -q '`ghost`' "$tmp/pr_body.txt" || fail "expected ghost in the PR body: $(cat "$tmp/pr_body.txt")"
  # ...and it's a note, not a veto: the removal still happened.
  assert_eq "leaf: remove 1.0-1" "$(git -C "$tmp/origin.git" log --format=%s main..remove/leaf)"

  rm -rf "$tmp"
  echo "PASS: test_unknown_package_is_reported_as_unchecked"
}

test_untracked_name_is_noop() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package not-a-package > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "nothing to remove" "$tmp/output.log" || fail "expected a no-op message: $(cat "$tmp/output.log")"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have opened a PR"

  rm -rf "$tmp"
  echo "PASS: test_untracked_name_is_noop"
}

test_untracked_name_alongside_tracked_one_warns_and_continues() {
  local tmp; tmp="$(setup_common)"

  run_remove_package "$tmp" --package leaf --package typo-name > "$tmp/output.log" 2>&1 \
    || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "nothing to remove for: typo-name" "$tmp/output.log" || fail "expected a warning about the untracked name: $(cat "$tmp/output.log")"
  assert_eq "leaf: remove 1.0-1" "$(git -C "$tmp/origin.git" log --format=%s main..remove/leaf)"

  rm -rf "$tmp"
  echo "PASS: test_untracked_name_alongside_tracked_one_warns_and_continues"
}

test_existing_open_pr_is_left_alone() {
  local tmp; tmp="$(setup_common)"
  echo '[{"number": 9, "url": "https://github.com/fake/fake/pull/9"}]' > "$tmp/fixtures/pr_list_remove_leaf.json"

  run_remove_package "$tmp" --package leaf > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "already has an open PR" "$tmp/output.log" || fail "expected existing-PR message: $(cat "$tmp/output.log")"
  grep -q "pull/9" "$tmp/output.log" || fail "expected the existing PR URL in output"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have created a new PR"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/remove/leaf" \
    && fail "should not have pushed a branch when a PR already exists"

  rm -rf "$tmp"
  echo "PASS: test_existing_open_pr_is_left_alone"
}

test_unverifiable_reverse_deps_abort() {
  local tmp; tmp="$(setup_common)"

  # fetch-info.sh degrading to {} means "couldn't ask upstream", not
  # "nothing depends on it" — removing on that basis is how a package
  # three others chain-build against disappears.
  set +e
  FETCH_INFO_EMPTY=1 run_remove_package "$tmp" --package leaf > "$tmp/output.log" 2>&1
  local status=$?
  set -e
  [[ $status -ne 0 ]] || fail "expected a nonzero exit when dependency data is unavailable"
  grep -q "returned no data" "$tmp/output.log" || fail "expected the unverifiable-deps error: $(cat "$tmp/output.log")"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have created a PR"

  rm -rf "$tmp"
  echo "PASS: test_unverifiable_reverse_deps_abort"
}

test_removes_a_leaf_package
test_refuses_when_upstream_dependent_still_tracked
test_refuses_on_recorded_aur_depends_only
test_removes_dependent_and_dependency_together
test_orphaned_dependency_is_reported_not_removed
test_unknown_package_is_reported_as_unchecked
test_untracked_name_is_noop
test_untracked_name_alongside_tracked_one_warns_and_continues
test_existing_open_pr_is_left_alone
test_unverifiable_reverse_deps_abort
echo "remove_package.sh tests passed"
