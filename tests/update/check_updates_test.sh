#!/usr/bin/env bash
set -euo pipefail

# Integration test for check_updates.sh: real git (against a local bare
# "origin"), a fake `gh`, and a fake backends/testdistro/fetch-info.sh
# (this test doesn't touch the network or the real archlinux backend at
# all). Exercises: dependency-based grouping into one PR, an unrelated
# package getting its own PR, a disabled/non-autoupdate package being
# left untouched, and the "existing PR already at target version -> no-op"
# path.

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
    # --head <branch> ... among the args
    branch=""
    for ((i=1; i<=$#; i++)); do
      if [[ "${!i}" == "--head" ]]; then
        j=$((i+1)); branch="${!j}"
      fi
    done
    fixture="${GH_FIXTURES:?}/pr_list_${branch//\//_}.json"
    [[ -f "$fixture" ]] && cat "$fixture" || echo "[]"
    ;;
  "pr create")
    title="" body="" head=""
    for ((i=1; i<=$#; i++)); do
      case "${!i}" in
        --title) j=$((i+1)); title="${!j}" ;;
        --body) j=$((i+1)); body="${!j}" ;;
        --head) j=$((i+1)); head="${!j}" ;;
      esac
    done
    echo "CREATE head=$head title=$title" >> "${GH_CALLS:?}"
    printf '%s\n' "$body" > "${GH_FIXTURES:?}/../body_${head//\//_}.txt"
    echo "https://github.com/fake/fake/pull/1"
    ;;
  "pr edit")
    number="$3" title="" body=""
    for ((i=1; i<=$#; i++)); do
      case "${!i}" in
        --title) j=$((i+1)); title="${!j}" ;;
        --body) j=$((i+1)); body="${!j}" ;;
      esac
    done
    echo "EDIT number=$number title=$title" >> "${GH_CALLS:?}"
    ;;
  *)
    echo "unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
GH
  chmod +x "$bin_dir/gh"
}

make_fake_fetch_info() {
  local path="$1"
  cat > "$path" <<'FI'
#!/usr/bin/env bash
set -euo pipefail
names_json="$(cat)"
jq -n --argjson names "$names_json" '
  {
    "pkg-a": {version: "1.1-1", depends: ["pkg-b"]},
    "pkg-b": {version: "2.1-1", depends: []},
    "pkg-c": {version: "3.1-1", depends: []}
  } as $all
  | $names | map(select(. as $n | $all | has($n))) | map({(.): $all[.]}) | add // {}
'
FI
  chmod +x "$path"
}

setup_repo_tree() {
  local tmp="$1"

  # A self-contained copy of just what check_updates.sh needs, laid out
  # exactly like the real repo (relative script paths matter) plus a fake
  # "testdistro" backend — never touches the real backends/archlinux/.
  mkdir -p "$tmp/build-kit/scripts/update" "$tmp/build-kit/scripts/registry" "$tmp/build-kit/scripts/lib" \
           "$tmp/build-kit/tools/depgraph" "$tmp/build-kit/backends/testdistro"
  cp "$repo_root/scripts/update/check_updates.sh" "$tmp/build-kit/scripts/update/"
  cp "$repo_root/scripts/registry/load_registry.sh" "$tmp/build-kit/scripts/registry/"
  cp "$repo_root/scripts/lib/toml.sh" "$repo_root/scripts/lib/run.sh" "$tmp/build-kit/scripts/lib/"
  cp "$repo_root/tools/depgraph/depgraph" "$tmp/build-kit/tools/depgraph/"
  chmod +x "$tmp/build-kit/scripts/update/check_updates.sh" "$tmp/build-kit/scripts/registry/load_registry.sh" \
    "$tmp/build-kit/tools/depgraph/depgraph"
  make_fake_fetch_info "$tmp/build-kit/backends/testdistro/fetch-info.sh"

  # No index-url.sh for testdistro on purpose — exercises the "no backend
  # index-url script" fallback (plain "- `subject`" line, no URL).
}

make_registry_repo() {
  local tmp="$1"
  local reg="$tmp/registry"
  mkdir -p "$reg"
  git -C "$reg" init -q -b main
  git -C "$reg" config user.email test@example.com
  git -C "$reg" config user.name test

  mkdir -p "$reg/testdistro/aur/pkg-a" "$reg/testdistro/aur/pkg-b" "$reg/testdistro/aur/pkg-c" "$reg/testdistro/aur/pkg-d"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-a"' 'version = "1.0-1"' 'autoupdate = true' > "$reg/testdistro/aur/pkg-a/pkg-a.toml"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-b"' 'version = "2.0-1"' 'autoupdate = true' > "$reg/testdistro/aur/pkg-b/pkg-b.toml"
  printf '%s\n' '[PACKAGES]' 'name = "pkg-c"' 'version = "3.0-1"' 'autoupdate = true' > "$reg/testdistro/aur/pkg-c/pkg-c.toml"
  # pkg-d: autoupdate=false — must never be touched, even though the fake
  # backend has no entry for it either (belt and suspenders).
  printf '%s\n' '[PACKAGES]' 'name = "pkg-d"' 'version = "9.0-1"' 'autoupdate = false' > "$reg/testdistro/aur/pkg-d/pkg-d.toml"
  git -C "$reg" add -A
  git -C "$reg" commit -q -m base

  # Bare "origin" so `git push --force origin <branch>` and `git fetch
  # origin <branch>` both work for real, without any network.
  git init -q --bare "$tmp/origin.git"
  git -C "$reg" remote add origin "$tmp/origin.git"
  git -C "$reg" push -q origin main
}

run_check_updates() {
  local tmp="$1"
  (
    cd "$tmp/registry"
    export PATH="$tmp/bin:$PATH"
    export GH_FIXTURES="$tmp/fixtures"
    export GH_LOG="$tmp/gh.log"
    export GH_CALLS="$tmp/gh_calls.log"
    export GH_TOKEN=fake
    : > "$GH_CALLS"
    "$tmp/build-kit/scripts/update/check_updates.sh" --registry-root .
  )
}

test_grouping_and_separate_pr_and_noop_disabled() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/fixtures"
  make_fake_gh "$tmp/bin"
  setup_repo_tree "$tmp"
  make_registry_repo "$tmp"
  # No pr_list fixtures -> every `gh pr list --head ...` call returns []
  # (no existing PR), matching the fresh-repo scenario.

  run_check_updates "$tmp" > "$tmp/output.log" 2>&1 || fail "check_updates.sh exited nonzero: $(cat "$tmp/output.log")"

  # --- pkg-a/pkg-b grouped (pkg-a depends on pkg-b, both dirty), topo
  # order puts pkg-b (the dependency) first ---
  local grouped_branch="bump/pkg-b+pkg-a"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$grouped_branch" \
    || fail "expected branch $grouped_branch to exist on origin"

  local a_version b_version
  a_version="$(git -C "$tmp/origin.git" show "$grouped_branch:testdistro/aur/pkg-a/pkg-a.toml" | grep version)"
  b_version="$(git -C "$tmp/origin.git" show "$grouped_branch:testdistro/aur/pkg-b/pkg-b.toml" | grep version)"
  [[ "$a_version" == *"1.1-1"* ]] || fail "pkg-a version not bumped on $grouped_branch: $a_version"
  [[ "$b_version" == *"2.1-1"* ]] || fail "pkg-b version not bumped on $grouped_branch: $b_version"

  # Two commits, dependency (pkg-b) first.
  local log
  log="$(git -C "$tmp/origin.git" log --format=%s "$grouped_branch" -2)"
  assert_eq $'pkg-a: update to 1.1-1\npkg-b: update to 2.1-1' "$log"

  grep -q "CREATE head=$grouped_branch" "$tmp/gh_calls.log" || fail "expected a PR create call for $grouped_branch"
  grep -q "Bundled because pkg-b, pkg-a depend on each other" "$tmp/body_${grouped_branch//\//_}.txt" \
    || fail "expected the bundling explanation in the PR body"
  # testdistro has no index-url.sh -> plain backtick line, no trailing URL.
  grep -qF '`pkg-b: update to 2.1-1`' "$tmp/body_${grouped_branch//\//_}.txt" \
    || fail "expected pkg-b's commit line with no URL in the PR body"

  # --- pkg-c: unrelated, its own PR ---
  local solo_branch="bump/pkg-c"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$solo_branch" \
    || fail "expected branch $solo_branch to exist on origin"
  grep -q "CREATE head=$solo_branch" "$tmp/gh_calls.log" || fail "expected a PR create call for $solo_branch"

  # --- pkg-d: autoupdate=false, never touched ---
  git -C "$tmp/origin.git" branch --list 'bump/pkg-d*' | grep -q . && fail "pkg-d should never get a bump branch"
  local d_on_main
  d_on_main="$(git -C "$tmp/registry" show "main:testdistro/aur/pkg-d/pkg-d.toml" | grep version)"
  [[ "$d_on_main" == *"9.0-1"* ]] || fail "pkg-d's version on main should be untouched: $d_on_main"

  # Back on main, no leftover local bump/* branch.
  local current_branch
  current_branch="$(git -C "$tmp/registry" branch --show-current)"
  assert_eq main "$current_branch"
  git -C "$tmp/registry" branch --list 'bump/*' | grep -q . && fail "no local bump/* branch should remain after the run"

  rm -rf "$tmp"
  echo "PASS: test_grouping_and_separate_pr_and_noop_disabled"
}

test_existing_pr_already_current_is_a_noop() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/fixtures"
  make_fake_gh "$tmp/bin"
  setup_repo_tree "$tmp"
  make_registry_repo "$tmp"

  # First run creates the branches for real.
  run_check_updates "$tmp" > "$tmp/output1.log" 2>&1 || fail "first run failed: $(cat "$tmp/output1.log")"

  # Second run: `gh pr list --head bump/pkg-c` now reports an existing
  # open PR — since the branch on origin is ALREADY at the exact target
  # version (nothing changed upstream between runs), this must be a
  # complete no-op: no new push, no gh pr create/edit call.
  echo '[{"number": 42, "title": "pkg-c: update to 3.1-1"}]' > "$tmp/fixtures/pr_list_bump_pkg-c.json"
  : > "$tmp/gh_calls.log"
  local before_sha after_sha
  before_sha="$(git -C "$tmp/origin.git" rev-parse bump/pkg-c)"

  run_check_updates "$tmp" > "$tmp/output2.log" 2>&1 || fail "second run failed: $(cat "$tmp/output2.log")"

  after_sha="$(git -C "$tmp/origin.git" rev-parse bump/pkg-c)"
  assert_eq "$before_sha" "$after_sha"
  # Only asserting about pkg-c's own branch here — bump/pkg-b+pkg-a has no
  # pr_list fixture in this second run either, so it's legitimately
  # reprocessed as "opening a new PR" again; that's not what this test is
  # about.
  grep -q "bump/pkg-c" "$tmp/gh_calls.log" && fail "expected no gh pr create/edit call for bump/pkg-c on the no-op run, got: $(cat "$tmp/gh_calls.log")"
  grep -q "already at the latest versions" "$tmp/output2.log" || fail "expected the no-op message in output: $(cat "$tmp/output2.log")"

  rm -rf "$tmp"
  echo "PASS: test_existing_pr_already_current_is_a_noop"
}

test_grouping_and_separate_pr_and_noop_disabled
test_existing_pr_already_current_is_a_noop
echo "check_updates tests passed"
