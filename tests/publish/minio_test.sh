#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/publish/minio.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_downloads="$3"
  local expected_removals="$4"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  touch "$tmp/package-4.0-1-x86_64.pkg.tar.zst"

  cat > "$tmp/bin/mc" <<'MC'
#!/usr/bin/env bash
set -euo pipefail

counter_file="${TEST_COUNTER_FILE:?}"
mode="${TEST_MODE:?}"
command="$1"
shift

increment() {
  local key="$1"
  local current=0
  [[ -f "$counter_file/$key" ]] && current="$(cat "$counter_file/$key")"
  printf '%s\n' "$((current + 1))" > "$counter_file/$key"
}

case "$command" in
  alias)
    exit 0
    ;;
  cp)
    source="$1"
    target="$2"
    if [[ "$target" == "." && "$source" == *"akaere.db.tar.gz" ]]; then
      increment downloads
      case "$mode" in
        bootstrap|retention-retry) printf 'mc: <ERROR> Unable to prepare URL for copying. Object does not exist\n' >&2; exit 1 ;;
        download-error) printf 'connection reset\n' >&2; exit 1 ;;
        inconsistent) exit 0 ;;
      esac
    fi
    if [[ "$target" == "." && "$source" == *"akaere.files.tar.gz" ]]; then
      increment downloads
      case "$mode" in
        bootstrap|retention-retry|inconsistent) printf 'mc: <ERROR> Unable to prepare URL for copying. Object does not exist\n' >&2; exit 1 ;;
        download-error) printf 'connection reset\n' >&2; exit 1 ;;
      esac
    fi
    exit 0
    ;;
  ls)
    if [[ "$mode" == "retention-retry" ]]; then
      printf '%s\n' \
        'package-4.0-1-x86_64.pkg.tar.zst' \
        'package-3.0-1-x86_64.pkg.tar.zst' \
        'package-2.0-1-x86_64.pkg.tar.zst' \
        'package-1.0-1-x86_64.pkg.tar.zst'
    fi
    exit 0
    ;;
  rm)
    increment removals
    if [[ "$mode" == "retention-retry" && "$(cat "$counter_file/removals")" -lt 3 ]]; then
      printf 'temporary R2 error\n' >&2
      exit 1
    fi
    exit 0
    ;;
esac
MC

  cat > "$tmp/bin/gpg" <<'GPG'
#!/usr/bin/env bash
set -euo pipefail
touch "${@: -1}.sig"
GPG

  cat > "$tmp/bin/repo-add" <<'REPO_ADD'
#!/usr/bin/env bash
set -euo pipefail
touch akaere.db.tar.gz akaere.db.tar.gz.sig akaere.files.tar.gz
REPO_ADD

  cat > "$tmp/bin/vercmp" <<'VERCMP'
#!/usr/bin/env bash
if (( $1 > $2 )); then
  echo 1
elif (( $1 < $2 )); then
  echo -1
else
  echo 0
fi
VERCMP
  chmod +x "$tmp/bin"/*

  set +e
  (
    cd "$tmp"
    PATH="$tmp/bin:$PATH" \
      TEST_COUNTER_FILE="$tmp" TEST_MODE="$mode" \
      R2_ENDPOINT=https://r2.invalid R2_ACCESS_KEY_ID=id R2_SECRET_ACCESS_KEY=secret R2_BUCKET=bucket \
      GPG_KEY_ID=key "$script" package package-4.0-1-x86_64.pkg.tar.zst
  ) >"$tmp/output" 2>&1
  local status=$?
  set -e

  assert_eq "$expected_status" "$status"
  assert_eq "$expected_downloads" "$(cat "$tmp/downloads" 2>/dev/null || echo 0)"
  assert_eq "$expected_removals" "$(cat "$tmp/removals" 2>/dev/null || echo 0)"
}

run_case bootstrap 0 2 0
run_case download-error 1 3 0
run_case inconsistent 1 2 0
run_case retention-retry 0 2 3

echo 'minio publish reliability tests passed'
