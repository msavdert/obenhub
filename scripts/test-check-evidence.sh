#!/usr/bin/env bash
# Test scripts/check-evidence.sh against fixture runs.jsonl files in a
# throwaway git repository. No docker, no network.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-evidence.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email t@example.invalid
git config user.name t
mkdir -p lab/x/results lab/packs lab/scenarios
echo 1 >lab/x/code
echo 1 >lab/packs/p
echo 1 >lab/scenarios/s
git add -A
git commit -q -m base
base=$(git rev-parse --short HEAD)
echo 2 >lab/x/code
git commit -q -am code
head=$(git rev-parse --short HEAD)
git checkout -q -b side
echo 3 >lab/x/side
git add -A
git commit -q -m side
off=$(git rev-parse --short HEAD)
git checkout -q main

# row SUITE SIZE SHA DIRTY PASS [START]; size "null" makes a legacy row
row() {
  jq -n -c --arg s "$1" --argjson z "$2" --arg sha "$3" --argjson d "$4" \
    --argjson p "$5" --arg t "${6:-2026-01-01T00:00:00Z}" \
    '{scenario: "a", suite: $s, suite_size: $z, git_sha: $sha, git_dirty: $d, pass: $p, start: $t}'
}

fail=0
# expect NAME EXIT PATTERN ARGS...: run the script on the fixture
expect() {
  local name=$1 want=$2 pat=$3 out rc=0
  shift 3
  out=$(bash "$script" "$@" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && grep -q -F -- "$pat" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc (want $want), pattern '$pat'" >&2
    printf '%s\n' "$out" >&2
    fail=1
  fi
}
fixture() { cat >lab/x/results/runs.jsonl; }

{ row s1 2 "$head" false true; row s1 2 "$head" false true; } | fixture
expect "complete passing suite" 0 "suite s1 ($head) is current" --strict x

{ row s1 2 "$head" false true; } | fixture
expect "partial suite" 1 "s1: not counted, partial (1 of 2" --strict x

{ row s1 2 "$head" false true; row s1 2 "$head" true true; } | fixture
expect "dirty row" 1 "not counted, ran on a dirty tree" --strict x

{ row s1 2 "$head" false true; row s1 2 "$base" false true; } | fixture
expect "mixed sha" 1 "not counted, mixed git_sha" --strict x

{ row s1 2 "$head" false true; row s1 2 "$head" false false; } | fixture
expect "failing record" 1 "not counted, has a failing record" --strict x

{ row s1 null "$head" false true; row s1 null "$head" false true; } | fixture
expect "legacy rows" 1 "not counted, legacy" --strict x
expect "legacy rows warn only" 0 "no complete passing suite" x

{ row s1 2 "$base" false true; row s1 2 "$base" false true; } | fixture
expect "stale config" 1 "predates changes in 1 files" --strict x

{ row s1 2 "$off" false true; row s1 2 "$off" false true; } | fixture
expect "sha not on main" 1 "is not on main" --strict x

{
  row s1 2 "$base" false true "2026-01-01T00:00:00Z"
  row s1 2 "$base" false true "2026-01-01T00:00:00Z"
  row s2 2 "$head" false true "2026-02-01T00:00:00Z"
  row s2 2 "$head" false true "2026-02-01T00:00:00Z"
} | fixture
expect "latest complete suite wins" 0 "suite s2 ($head) is current" --strict x

expect "missing lab" 1 "no lab/y/results/runs.jsonl" --strict y

exit "$fail"
