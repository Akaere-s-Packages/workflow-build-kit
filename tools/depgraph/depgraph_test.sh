#!/usr/bin/env bash
set -euo pipefail

# Fixture-based tests for depgraph, mirroring the semantics of the old
# scripts/registry/aur_graph.py (connected_components / topo_order /
# layered_order) it replaces. Deliberately no network/live-AUR dependency —
# same convention as every other test in tests/: static fixtures only.

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tool_dir"
make -s >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- diamond: d depends on b,c; b,c depend on a; e is isolated ---
diamond_graph="$tmp/diamond.txt"
printf 'a\t\nb\ta\nc\ta\nd\tb,c\ne\t\n' > "$diamond_graph"
full_subset="$tmp/full_subset.txt"
printf 'a\nb\nc\nd\ne\n' > "$full_subset"

components="$(./depgraph components --subset "$full_subset" < "$diamond_graph")"
expected_components=$'a b c d\ne'
[[ "$components" == "$expected_components" ]] || fail "diamond components: got [$components]"

toposort="$(./depgraph toposort --subset "$full_subset" < "$diamond_graph")"
expected_toposort=$'a\nb\nc\nd\ne'
[[ "$toposort" == "$expected_toposort" ]] || fail "diamond toposort: got [$toposort]"
# d must come after both b and c, and both after a — check relative order,
# not just the exact (also-correct) string above, in case tie-breaking ever
# changes for equally-ready nodes.
pos() { grep -nxF "$1" <<<"$toposort" | cut -d: -f1; }
(( $(pos a) < $(pos b) && $(pos a) < $(pos c) && $(pos b) < $(pos d) && $(pos c) < $(pos d) )) ||
  fail "diamond toposort violates dependency order: $toposort"

layers="$(./depgraph layers --subset "$full_subset" --max-layers 5 < "$diamond_graph")"
expected_layers='[["a","e"],["b","c"],["d"]]'
[[ "$layers" == "$expected_layers" ]] || fail "diamond layers: got [$layers]"

# --- subset restriction: excluding 'a' makes b/c look dependency-free ---
restricted_subset="$tmp/restricted_subset.txt"
printf 'b\nc\nd\n' > "$restricted_subset"
restricted_layers="$(./depgraph layers --subset "$restricted_subset" --max-layers 5 < "$diamond_graph")"
[[ "$restricted_layers" == '[["b","c"],["d"]]' ]] || fail "restricted-subset layers: got [$restricted_layers]"
restricted_components="$(./depgraph components --subset "$restricted_subset" < "$diamond_graph")"
[[ "$restricted_components" == "b c d" ]] || fail "restricted-subset components: got [$restricted_components]"

# --- empty subset: valid, empty output for every command ---
empty_subset="$tmp/empty_subset.txt"
: > "$empty_subset"
[[ -z "$(./depgraph components --subset "$empty_subset" < "$diamond_graph")" ]] || fail "empty subset components should print nothing"
[[ -z "$(./depgraph toposort --subset "$empty_subset" < "$diamond_graph")" ]] || fail "empty subset toposort should print nothing"
[[ "$(./depgraph layers --subset "$empty_subset" --max-layers 5 < "$diamond_graph")" == "[]" ]] || fail "empty subset layers should be []"

# --- cycle: x depends on y, y depends on x ---
cycle_graph="$tmp/cycle.txt"
printf 'x\ty\ny\tx\n' > "$cycle_graph"
cycle_subset="$tmp/cycle_subset.txt"
printf 'x\ny\n' > "$cycle_subset"

# toposort must tolerate the cycle (never hang, still emit both names).
cycle_toposort="$(timeout 5 ./depgraph toposort --subset "$cycle_subset" < "$cycle_graph")"
[[ "$(sort <<<"$cycle_toposort")" == "$(printf 'x\ny')" ]] || fail "cycle toposort should still emit both names: got [$cycle_toposort]"

# layers must reject a cycle: exit 1, nothing on stdout (not truncated JSON).
set +e
cycle_layers_out="$(./depgraph layers --subset "$cycle_subset" --max-layers 5 < "$cycle_graph" 2>/dev/null)"
cycle_layers_status=$?
set -e
[[ $cycle_layers_status -ne 0 ]] || fail "layers should reject a cycle (exit nonzero)"
[[ -z "$cycle_layers_out" ]] || fail "layers must print nothing on stdout when it errors, got [$cycle_layers_out]"

# --- chain of 4 exceeding max-layers: must error, not silently misorder ---
chain_graph="$tmp/chain.txt"
printf 'p1\t\np2\tp1\np3\tp2\np4\tp3\n' > "$chain_graph"
chain_subset="$tmp/chain_subset.txt"
printf 'p1\np2\np3\np4\n' > "$chain_subset"

set +e
chain_out="$(./depgraph layers --subset "$chain_subset" --max-layers 2 < "$chain_graph" 2>/dev/null)"
chain_status=$?
set -e
[[ $chain_status -ne 0 ]] || fail "layers should reject a chain deeper than --max-layers"
[[ -z "$chain_out" ]] || fail "layers must print nothing on stdout when it errors, got [$chain_out]"

# ...but the same chain fits comfortably within a higher cap.
chain_ok="$(./depgraph layers --subset "$chain_subset" --max-layers 5 < "$chain_graph")"
[[ "$chain_ok" == '[["p1"],["p2"],["p3"],["p4"]]' ]] || fail "chain layers within cap: got [$chain_ok]"

echo "depgraph tests passed"
