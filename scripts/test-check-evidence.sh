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
mkdir -p lab/x/results lab/x/scenarios lab/packs lab/scenarios
printf 'a\nb\n' >lab/x/scenarios/suite.txt
touch lab/x/scenarios/a.sh lab/x/scenarios/b.sh lab/x/scenarios/lib.sh
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

t1=2026-01-01T00:00:00Z
t2=2026-02-01T00:00:00Z

# row SUITE SIZE SHA DIRTY PASS START SCENARIO: SIZE is JSON ("null" makes a
# legacy row, SUITE "-" a suite-less row); the suite list is a, b
row() {
  jq -n -c --arg s "$1" --argjson z "$2" --arg sha "$3" --argjson d "$4" \
    --argjson p "$5" --arg t "$6" --arg n "$7" \
    '{scenario: $n, suite: (if $s == "-" then null else $s end), suite_size: $z,
      git_sha: $sha, git_dirty: $d, pass: $p, start: $t}'
}
# pair SUITE SHA START: the two records of a complete clean passing suite
pair() { row "$1" 2 "$2" false true "$3" a; row "$1" 2 "$2" false true "$3" b; }

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

pair s1 "$head" $t1 | fixture
expect "complete passing suite" 0 "suite s1 ($head) is current" --strict x

row s1 2 "$head" false true $t1 a | fixture
expect "partial suite" 1 "s1: not counted, partial (1 of 2" --strict x

{ row s1 2 "$head" false true $t1 a; row s1 2 "$head" false true $t1 a; } | fixture
expect "duplicate rows fill no gap" 1 "not counted, duplicate scenario records" --strict x

{ row s1 2 "$head" false true $t1 a; row s1 2 "$head" true true $t1 b; } | fixture
expect "dirty row" 1 "not counted, ran on a dirty tree" --strict x

{ row s1 2 "$head" false true $t1 a; row s1 2 "$base" false true $t1 b; } | fixture
expect "mixed sha" 1 "not counted, mixed git_sha" --strict x

{ row s1 2 "$head" false true $t1 a; row s1 3 "$head" false true $t1 b; } | fixture
expect "mixed suite_size" 1 "not counted, mixed suite_size" --strict x

{ row s1 2 "$head" false true $t1 a; row s1 2 "$head" false false $t1 b; } | fixture
expect "failing record" 1 "not counted, has a failing record" --strict x

{ row s1 null "$head" false true $t1 a; row s1 null "$head" false true $t1 b; } | fixture
expect "legacy rows" 1 "not counted, legacy" --strict x
expect "legacy rows warn only" 0 "no complete passing suite" x

{ row s1 0 "$head" false true $t1 a; row s1 0 "$head" false true $t1 b; } | fixture
expect "suite_size 0" 1 "suite_size not a positive integer" --strict x

{ row s1 '"2"' "$head" false true $t1 a; row s1 '"2"' "$head" false true $t1 b; } | fixture
expect "suite_size string" 1 "suite_size not a positive integer" --strict x

row s1 1 "$head" false true $t1 a | fixture
expect "subset suite vs full list" 1 "scenario set differs from suite.txt" --strict x

{ row - null "$head" false true $t1 a; row - null "$head" false true $t1 b; } | fixture
expect "suite-less rows are ignored" 1 "no complete passing suite recorded" --strict x

pair s1 "$base" $t1 | fixture
expect "stale config" 1 "predates changes in 1 files" --strict x

pair s1 "$off" $t1 | fixture
expect "sha not on main" 1 "is not on main" --strict x

{ pair s1 "$base" $t1; pair s2 "$head" $t2; } | fixture
expect "latest complete suite wins" 0 "suite s2 ($head) is current" --strict x

# the chronologically later suite has the alphabetically smaller id
{ pair zz "$base" $t1; pair aa "$head" $t2; } | fixture
expect "chronological, not alphabetical" 0 "suite aa ($head) is current" --strict x

# interleaved records of two suites; the newer one (s2) is partial
{ row s1 2 "$head" false true $t1 a; row s2 2 "$head" false true $t2 a; row s1 2 "$head" false true $t1 b; } | fixture
expect "interleaved suites, partial one reported" 0 "s2: not counted, partial" x
expect "interleaved suites, complete one counts" 0 "suite s1 ($head) is current" --strict x

{ pair s1 "$head" $t1; echo '{not json'; } | fixture
expect "malformed line warns" 0 "unreadable" x
expect "malformed line fails strict" 1 "unreadable" --strict x

# mixed config_sha256 within one suite
{ row s1 2 "$head" false true $t1 a | jq -c '. + {config_sha256: "aaa"}'
  row s1 2 "$head" false true $t1 b | jq -c '. + {config_sha256: "bbb"}'; } | fixture
expect "mixed config hash" 1 "not counted, mixed config_sha256" --strict x
pair s1 "$head" $t1 | jq -c '. + {config_sha256: "aaa"}' | fixture
expect "one config hash" 0 "suite s1 ($head) is current" --strict x

# scenario scripts vs suite.txt (lab x has a.sh, b.sh and the helper lib.sh)
pair s1 "$head" $t1 | fixture
expect "scripts match suite.txt" 0 "suite s1 ($head) is current" --strict x
touch lab/x/scenarios/c.sh
expect "script missing from suite.txt" 1 "< c" x
rm lab/x/scenarios/c.sh
printf 'a\nb\nd\n' >lab/x/scenarios/suite.txt
expect "suite.txt name without script" 1 "> d" x
git checkout -q lab/x/scenarios/suite.txt

# prose and cross-lab mounts, on a lab named pgha
mkdir -p lab/pgha/results lab/pgha/scenarios lab/stage3/grafana/dashboards lab/slice1/grafana/dashboards
printf 'a\nb\n' >lab/pgha/scenarios/suite.txt
touch lab/pgha/scenarios/a.sh lab/pgha/scenarios/b.sh lab/pgha/scenarios/lib.sh
echo 1 >lab/pgha/README.md
echo 1 >lab/stage3/grafana/dashboards/d.json
echo 1 >lab/slice1/grafana/dashboards/d.json
git add -A
git commit -q -m pgha
p0=$(git rev-parse --short HEAD)
pair s1 "$p0" $t1 >lab/pgha/results/runs.jsonl
echo 2 >lab/pgha/README.md
git commit -q -am readme
expect "README-only change passes strict" 0 "suite s1 ($p0) is current" --strict pgha
git reset -q --hard "$p0"
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am script
expect "script change fails strict" 1 "lab/pgha/scenarios/a.sh" --strict pgha
git reset -q --hard "$p0"
echo 2 >lab/stage3/grafana/dashboards/d.json
git commit -q -am dash
expect "cross-mounted dashboard marks pgha stale" 1 "lab/stage3/grafana/dashboards/d.json" --strict pgha
git reset -q --hard "$p0"
echo 2 >lab/slice1/grafana/dashboards/d.json
git commit -q -am dash
expect "second cross-mounted dashboard marks pgha stale" 1 "lab/slice1/grafana/dashboards/d.json" --strict pgha
git reset -q --hard "$p0"

expect "missing lab" 1 "no lab/y/results/runs.jsonl" --strict y

exit "$fail"
