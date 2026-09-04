#!/usr/bin/env bash
set -euo pipefail

# Regression guard for a real production failure: scripts/update/check_updates.sh
# shipped without its executable bit set, so version-check.yml (which invokes
# it directly, no `bash` prefix) failed in real CI with "Permission denied"
# (exit 126) the first time it ran. Every script invocation in the workflow
# YAML files was separately hardened with an explicit `bash` prefix so this
# can't break the pipeline again regardless of file mode — but the
# executable bit itself is still worth checking directly: it's still wrong
# by Unix convention for a script meant to be run standalone, someone could
# invoke it directly outside the YAML, and the existing per-script test
# harnesses (check_updates_test.sh etc.) couldn't catch this class of bug
# themselves — they `chmod +x` their own copies unconditionally as part of
# test setup, which masks exactly this problem on the real source file.
#
# Any script whose own header says "Sourced, not run standalone" (the
# convention every library file in this repo uses — scripts/lib/*.sh,
# scripts/publish/repo_lib.sh, backends/*/repo_lib.sh) is intentionally
# exempt: those are never meant to have the bit set.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail_count=0

while IFS= read -r -d '' file; do
  rel="${file#"$repo_root"/}"

  first_line="$(head -n1 "$file")"
  [[ "$first_line" == "#!"*bash* || "$first_line" == "#!/bin/sh" ]] || continue

  grep -qi "sourced, not run" "$file" && continue

  if [[ ! -x "$file" ]]; then
    echo "FAIL: $rel has a bash shebang and isn't marked sourced-only, but is not executable" >&2
    fail_count=$((fail_count + 1))
  fi
done < <(find "$repo_root" -name "*.sh" -not -path "*/.git/*" -print0)

if (( fail_count > 0 )); then
  echo "FAIL: $fail_count script(s) missing the executable bit" >&2
  exit 1
fi

echo "executable-bit tests passed"
