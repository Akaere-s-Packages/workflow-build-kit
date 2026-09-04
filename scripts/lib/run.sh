# Shared subprocess-run helpers for scripts/update/*.sh. Sourced, not run
# standalone. Deliberately captures stdout/stderr into variables (so
# callers can parse gh/git JSON output) while STILL printing both, unlike a
# plain `$(...)` capture — a previous version of this logic swallowed
# output until failure, which made a failed git/gh call show up as a bare
# error with no indication of what the command itself actually said.

# run <cmd...>: prints "+ cmd", runs it, prints its stdout/stderr, and
# leaves the result in $run_stdout/$run_status. Never `set -e`s the caller
# away — a failed gh/git call here is routine, not exceptional, so callers
# check $run_status (or run's own exit status) explicitly.
run() {
  echo "+ $*" >&2
  local out_file err_file err_text
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  "$@" >"$out_file" 2>"$err_file"
  run_status=$?
  run_stdout="$(cat "$out_file")"
  err_text="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"
  [[ -n "$run_stdout" ]] && printf '%s\n' "$run_stdout"
  [[ -n "$err_text" ]] && printf '%s\n' "$err_text" >&2
  return "$run_status"
}

# retry_run <cmd...>: same as run(), but for network-bound calls (git
# fetch/push, gh pr *) — worth surviving a transient GitHub/network blip
# rather than failing the whole run over one. Local-only git operations
# (checkout, add, commit, branch -D) don't need this.
retry_run() {
  local attempts=3 delay=5 n=1
  while true; do
    if run "$@"; then
      return 0
    fi
    if (( n >= attempts )); then
      echo "::error::command failed after $attempts attempts: $*" >&2
      return "$run_status"
    fi
    echo "::warning::command failed (attempt $n/$attempts), retrying in ${delay}s: $*" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}
