#!/usr/bin/env bash
set -euo pipefail

# Integration test for add_package.sh: real git (against a local bare
# "origin"), a fake `gh`, and a fake backends/testdistro/{fetch-info,
# classify-dep,index-url}.sh — no network, no real AUR/archlinux.org.

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
    title="" head=""
    for ((i=1; i<=$#; i++)); do
      case "${!i}" in
        --title) j=$((i+1)); title="${!j}" ;;
        --head) j=$((i+1)); head="${!j}" ;;
      esac
    done
    echo "CREATE head=$head title=$title" >> "${GH_CALLS:?}"
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

  cat > "$dir/fetch-info.sh" <<'FI'
#!/usr/bin/env bash
set -euo pipefail
names_json="$(cat)"
# Logs each invocation's requested names (one line, comma-joined) so tests
# can assert on how many separate calls (= AUR RPC round-trips in the real
# backend) a resolution actually made — the whole point of batching by
# BFS wave instead of one call per package.
if [[ -n "${FETCH_INFO_CALL_LOG:-}" ]]; then
  jq -r 'join(",")' <<<"$names_json" >> "$FETCH_INFO_CALL_LOG"
fi
jq -n --argjson names "$names_json" '
  {
    "root-simple": {version: "1.0-1", depends: ["some-official-lib"]},
    "root-chained": {version: "2.0-1", depends: ["dep-aur"]},
    "dep-aur": {version: "0.5-1", depends: []},
    "root-partial": {version: "3.0-1", depends: ["dep-tracked"]},
    "root-bad": {version: "4.0-1", depends: ["totally-missing"]},
    "root-wide": {version: "5.0-1", depends: ["dep-x", "dep-y", "dep-z"]},
    "dep-x": {version: "0.1-1", depends: []},
    "dep-y": {version: "0.2-1", depends: []},
    "dep-z": {version: "0.3-1", depends: []}
  } as $all
  | $names | map(select(. as $n | $all | has($n))) | map({(.): $all[.]}) | add // {}
'
FI

  cat > "$dir/classify-dep.sh" <<'CD'
#!/usr/bin/env bash
set -euo pipefail
names_json="$(cat)"
jq -n --argjson names "$names_json" '
  {
    "some-official-lib": "official",
    "dep-aur": "aur",
    "dep-tracked": "aur",
    "totally-missing": "aur",
    "dep-x": "aur",
    "dep-y": "aur",
    "dep-z": "aur"
  } as $all
  | $names | map({(.): ($all[.] // "official")}) | add // {}
'
CD

  cat > "$dir/index-url.sh" <<'IU'
#!/usr/bin/env bash
set -euo pipefail
echo "https://aur.example.test/packages/${1:?pkgbase required}"
IU

  chmod +x "$dir/fetch-info.sh" "$dir/classify-dep.sh" "$dir/index-url.sh"
}

setup_repo_tree() {
  local tmp="$1"
  mkdir -p "$tmp/build-kit/scripts/update" "$tmp/build-kit/scripts/registry" "$tmp/build-kit/scripts/lib" \
           "$tmp/build-kit/tools/depgraph" "$tmp/build-kit/backends/testdistro"
  cp "$repo_root/scripts/update/add_package.sh" "$tmp/build-kit/scripts/update/"
  cp "$repo_root/scripts/registry/load_registry.sh" "$tmp/build-kit/scripts/registry/"
  cp "$repo_root/scripts/lib/toml.sh" "$repo_root/scripts/lib/run.sh" "$tmp/build-kit/scripts/lib/"
  cp "$repo_root/tools/depgraph/depgraph" "$tmp/build-kit/tools/depgraph/"
  chmod +x "$tmp/build-kit/scripts/update/add_package.sh" "$tmp/build-kit/scripts/registry/load_registry.sh" \
    "$tmp/build-kit/tools/depgraph/depgraph"
  make_fake_backend "$tmp/build-kit/backends/testdistro"
}

make_registry_repo() {
  local tmp="$1" reg="$tmp/registry"
  mkdir -p "$reg/testdistro/aur/dep-tracked"
  printf '%s\n' '[PACKAGES]' 'name = "dep-tracked"' 'version = "0.9-1"' 'autoupdate = true' \
    > "$reg/testdistro/aur/dep-tracked/dep-tracked.toml"

  git -C "$reg" init -q -b main
  git -C "$reg" config user.email test@example.com
  git -C "$reg" config user.name test
  git -C "$reg" add -A
  git -C "$reg" commit -q -m base

  git init -q --bare "$tmp/origin.git"
  git -C "$reg" remote add origin "$tmp/origin.git"
  git -C "$reg" push -q origin main
}

run_add_package() {
  local tmp="$1" package="$2"
  (
    cd "$tmp/registry"
    export PATH="$tmp/bin:$PATH"
    export GH_FIXTURES="$tmp/fixtures"
    export GH_LOG="$tmp/gh.log"
    export GH_CALLS="$tmp/gh_calls.log"
    export GH_TOKEN=fake
    export FETCH_INFO_CALL_LOG="$tmp/fetch_info_calls.log"
    : >> "$GH_CALLS"
    : >> "$FETCH_INFO_CALL_LOG"
    "$tmp/build-kit/scripts/update/add_package.sh" \
      --registry-root . --package "$package" --distro testdistro --type aur
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

test_simple_no_deps() {
  local tmp; tmp="$(setup_common)"

  run_add_package "$tmp" root-simple > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "resolved 1 new package" "$tmp/output.log" || fail "expected 1 new package: $(cat "$tmp/output.log")"

  local branch="add/root-simple"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch on origin"
  local toml
  toml="$(git -C "$tmp/origin.git" show "$branch:testdistro/aur/root-simple/root-simple.toml")"
  [[ "$toml" == *'version = "1.0-1"'* ]] || fail "unexpected toml: $toml"
  [[ "$toml" != *"aur_depends"* ]] || fail "root-simple has no AUR deps, aur_depends should be omitted: $toml"

  grep -q "CREATE head=$branch title=add root-simple$" "$tmp/gh_calls.log" || fail "unexpected PR create call: $(cat "$tmp/gh_calls.log")"

  rm -rf "$tmp"
  echo "PASS: test_simple_no_deps"
}

test_chained_dependency() {
  local tmp; tmp="$(setup_common)"

  run_add_package "$tmp" root-chained > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "resolved 2 new package" "$tmp/output.log" || fail "expected 2 new packages: $(cat "$tmp/output.log")"

  local branch="add/dep-aur+root-chained"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch on origin"

  # dependency committed first
  local log
  log="$(git -C "$tmp/origin.git" log --format=%s "$branch" -2)"
  assert_eq $'root-chained: add 2.0-1\ndep-aur: add 0.5-1' "$log"

  local root_toml
  root_toml="$(git -C "$tmp/origin.git" show "$branch:testdistro/aur/root-chained/root-chained.toml")"
  [[ "$root_toml" == *'aur_depends = ["dep-aur"]'* ]] || fail "root-chained should list dep-aur: $root_toml"

  git -C "$tmp/origin.git" show "$branch:testdistro/aur/dep-aur/dep-aur.toml" >/dev/null 2>&1 \
    || fail "dep-aur.toml should also have been created"

  grep -q "CREATE head=$branch" "$tmp/gh_calls.log" || fail "expected a PR create call"

  rm -rf "$tmp"
  echo "PASS: test_chained_dependency"
}

test_already_tracked_root_is_noop() {
  local tmp; tmp="$(setup_common)"

  run_add_package "$tmp" dep-tracked > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "already tracked" "$tmp/output.log" || fail "expected no-op message: $(cat "$tmp/output.log")"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have opened a PR"

  rm -rf "$tmp"
  echo "PASS: test_already_tracked_root_is_noop"
}

test_partial_dependency_already_tracked() {
  local tmp; tmp="$(setup_common)"

  run_add_package "$tmp" root-partial > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  # only root-partial is new; dep-tracked is already tracked and must not
  # be re-added, but root-partial's aur_depends must still list it (it's
  # still needed as a real build-time chain dependency regardless of
  # Registry-tracking status).
  grep -q "resolved 1 new package" "$tmp/output.log" || fail "expected exactly 1 new package: $(cat "$tmp/output.log")"

  local branch="add/root-partial"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch"
  # dep-tracked.toml existing on this branch is expected — it's inherited
  # from main (dep-tracked was already tracked before this run). What
  # must NOT happen is add_package.sh re-committing it: exactly one new
  # commit (root-partial's own) beyond main.
  local new_commit_count
  new_commit_count="$(git -C "$tmp/origin.git" log --format=%s main.."$branch" | wc -l)"
  assert_eq 1 "$new_commit_count"
  local branch_log
  branch_log="$(git -C "$tmp/origin.git" log --format=%s main.."$branch")"
  [[ "$branch_log" == "root-partial: add 3.0-1" ]] || fail "unexpected commit(s) beyond main: $branch_log"

  local root_toml
  root_toml="$(git -C "$tmp/origin.git" show "$branch:testdistro/aur/root-partial/root-partial.toml")"
  [[ "$root_toml" == *'aur_depends = ["dep-tracked"]'* ]] || fail "root-partial should still list dep-tracked in aur_depends: $root_toml"

  rm -rf "$tmp"
  echo "PASS: test_partial_dependency_already_tracked"
}

test_existing_open_pr_is_left_alone() {
  local tmp; tmp="$(setup_common)"
  echo '[{"number": 9, "url": "https://github.com/fake/fake/pull/9"}]' > "$tmp/fixtures/pr_list_add_root-simple.json"

  run_add_package "$tmp" root-simple > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "already has an open PR" "$tmp/output.log" || fail "expected existing-PR message: $(cat "$tmp/output.log")"
  grep -q "pull/9" "$tmp/output.log" || fail "expected the existing PR URL in output"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have created a new PR"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/add/root-simple" \
    && fail "should not have pushed a branch when a PR already exists"

  rm -rf "$tmp"
  echo "PASS: test_existing_open_pr_is_left_alone"
}

test_unresolvable_dependency_errors() {
  local tmp; tmp="$(setup_common)"

  set +e
  run_add_package "$tmp" root-bad > "$tmp/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "expected a nonzero exit for an unresolvable dependency"
  grep -q "totally-missing" "$tmp/output.log" || fail "expected the unresolvable name in the error: $(cat "$tmp/output.log")"
  [[ -s "$tmp/gh_calls.log" ]] && fail "should not have created a PR on failure"

  rm -rf "$tmp"
  echo "PASS: test_unresolvable_dependency_errors"
}

test_wide_closure_batches_fetch_info_by_wave() {
  local tmp; tmp="$(setup_common)"

  run_add_package "$tmp" root-wide > "$tmp/output.log" 2>&1 || fail "run failed: $(cat "$tmp/output.log")"
  grep -q "resolved 4 new package" "$tmp/output.log" || fail "expected 4 new packages (root + 3 siblings): $(cat "$tmp/output.log")"

  local branch="add/dep-x+dep-y+dep-z+root-wide"
  git -C "$tmp/origin.git" show-ref --verify --quiet "refs/heads/$branch" || fail "expected branch $branch"

  # The whole point: root-wide's 3 AUR-only siblings all sit at the same
  # BFS depth, so resolving them must take exactly 2 fetch-info.sh calls
  # total (one for the root wave, one batched call for all 3 siblings
  # together) — NOT 4 (one per package), which is what a naive
  # one-call-per-node loop would do. Each real call is a live AUR RPC
  # round-trip, so this is the difference between O(depth) and O(closure
  # size) network requests.
  local call_count
  call_count="$(grep -c . "$tmp/fetch_info_calls.log")"
  assert_eq 2 "$call_count"
  local second_call
  second_call="$(sed -n '2p' "$tmp/fetch_info_calls.log")"
  assert_eq "dep-x,dep-y,dep-z" "$(tr ',' '\n' <<<"$second_call" | LC_ALL=C sort | paste -sd, -)"

  local root_toml
  root_toml="$(git -C "$tmp/origin.git" show "$branch:testdistro/aur/root-wide/root-wide.toml")"
  [[ "$root_toml" == *'aur_depends = ["dep-x","dep-y","dep-z"]'* ]] || fail "root-wide aur_depends: $root_toml"

  rm -rf "$tmp"
  echo "PASS: test_wide_closure_batches_fetch_info_by_wave"
}

test_simple_no_deps
test_chained_dependency
test_already_tracked_root_is_noop
test_partial_dependency_already_tracked
test_existing_open_pr_is_left_alone
test_unresolvable_dependency_errors
test_wide_closure_batches_fetch_info_by_wave
echo "add_package.sh tests passed"
