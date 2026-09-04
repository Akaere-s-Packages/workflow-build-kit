#!/usr/bin/env bash
set -euo pipefail

# Regression test for a real production failure: visual-studio-code-bin's
# file list (~9000 files, nearly all resized by the version bump) produced
# a diff comment body over GitHub's hard 65536-character limit on an
# issue/PR comment, and `comment` job in pr-preview.yml failed outright
# with a 422 ("Body is too long") instead of posting anything at all.
# diff.py now caps the file table to a fixed character budget
# (MAX_ROWS_CHARS) and notes how many rows got left out, rather than
# emitting an unbounded table.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A domain guaranteed to never resolve to a real published-data endpoint —
# forces fetch_published() to fail and treat everything as newly added,
# so this test never depends on (or is slowed by) a real network call.
bogus_base_url="http://invalid.invalid"

# --- large file list: must stay under GitHub's real 65536-char cap ---
python3 - "$tmp/big_file_list.json" <<'PY'
import json, sys
files = [{"path": f"/usr/share/fake/locale-file-{i:05d}.pak", "size_bytes": 1000 + i} for i in range(3000)]
json.dump({"files": files, "package_size_bytes": sum(f["size_bytes"] for f in files)}, open(sys.argv[1], "w"))
PY

body="$(python3 "$repo_root/scripts/preview/diff.py" \
  --name visual-studio-code-bin --old-version 1.0-1 --new-version 1.1-1 \
  --build-status success --job-url https://example.com/job \
  --file-list "$tmp/big_file_list.json" \
  --published-base-url "$bogus_base_url" 2>/dev/null)"

body_len=${#body}
(( body_len < 65536 )) || {
  echo "FAIL: comment body is $body_len chars, still over GitHub's 65536 limit" >&2
  exit 1
}

grep -q '(truncated)' <<< "$body" || {
  echo "FAIL: expected a truncation notice in the comment body for a file list this large" >&2
  exit 1
}

# --- small file list: must NOT be truncated (no false positive) ---
python3 - "$tmp/small_file_list.json" <<'PY'
import json, sys
json.dump({"files": [{"path": "/usr/bin/foo", "size_bytes": 100}], "package_size_bytes": 100}, open(sys.argv[1], "w"))
PY

small_body="$(python3 "$repo_root/scripts/preview/diff.py" \
  --name foo --new-version 1.0-1 --build-status success --job-url https://example.com/job \
  --file-list "$tmp/small_file_list.json" \
  --published-base-url "$bogus_base_url" 2>/dev/null)"

if grep -q '(truncated)' <<< "$small_body"; then
  echo "FAIL: a 1-file diff should never be truncated" >&2
  exit 1
fi
grep -q '/usr/bin/foo' <<< "$small_body" || {
  echo "FAIL: expected the single file's row in the untruncated output" >&2
  exit 1
}

echo "PASS: diff.py caps comment body under GitHub's 65536-char limit"
