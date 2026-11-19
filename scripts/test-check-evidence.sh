#!/usr/bin/env bash
# Test scripts/check-evidence.sh against fixture runs.jsonl files in a
# throwaway git repository. No docker, no network.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-evidence.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
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
t3=2026-03-01T00:00:00Z

# row SUITE SIZE SHA DIRTY PASS START SCENARIO: SIZE is JSON ("null" makes a
# legacy row, SUITE "-" a suite-less row); the suite list is a, b
row() {
  jq -n -c --arg s "$1" --argjson z "$2" --arg sha "$3" --argjson d "$4" \
    --argjson p "$5" --arg t "$6" --arg n "$7" \
    '{scenario: $n, suite: (if $s == "-" then null else $s end), suite_size: $z,
      git_sha: $sha, git_dirty: $d, pass: $p, start: $t, config_sha256: "c1"}'
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
fixture_pgha() { cat >lab/pgha/results/runs.jsonl; }

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

# a failing suite after the counted one: stale until that scenario passes again
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; } | fixture
expect "pass then fail is stale" 1 "x: a failed in suite s2 ($head" --strict x
expect "pass then fail is stale with --full" 1 "x: a failed in suite s2" --strict --full x
expect "pass then fail: --sha names the failed scenario" 0 "failed a" --sha x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; pair s3 "$head" $t3; } | fixture
expect "a later full suite clears the failure" 0 "suite s3 ($head) is current" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; row s3 1 "$head" false true $t3 a; } | fixture
expect "a later passing targeted suite of it clears the failure" 0 "targeted s3 ($head: a) is current" --strict x
expect "a later passing targeted suite clears it under --full too" 0 "suite s1 ($head) is current" --strict --full x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; row s3 1 "$head" false true $t3 b; } | fixture
expect "a pass of another scenario does not clear it" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; row s3 1 "$base" false true $t3 a; } | fixture
expect "a pass on a commit before the evidence does not clear it" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; row s3 1 "$head" false true $t3 a | jq -c '.config_sha256 = "c2"'; } | fixture
expect "a pass on another configuration does not clear it" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a; row s3 2 "$head" false true $t3 a; } | fixture
expect "a pass in a partial suite does not clear it" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s3 1 "$head" false true 2026-01-15T00:00:00Z a; row s2 2 "$head" false false $t2 a; } | fixture
expect "a pass that started before the failure does not clear it" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t1 a; } | fixture
expect "a failure at the start of the full suite does not count" 0 "suite s1 ($head) is current" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a | jq -c '.start = ""'; } | fixture
expect "a failure with an empty start counts as the latest" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s3 1 "$head" false true 2026-01-15T00:00:00Z a; row s2 2 "$head" false false $t2 a | jq -c '.suite = ""'; } | fixture
expect "an empty suite id does not shift the failure's start" 1 "x: a failed in suite  (" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 gone; } | fixture
expect "a failed scenario no longer in suite.txt is dropped" 0 "suite s1 ($head) is current" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false false $t2 a | jq -c 'del(.start)'; } | fixture
expect "a failure without start counts as the latest" 1 "x: a failed in suite s2" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" false true $t2 a | jq -c '.pass = null'; } | fixture
expect "a record with pass null counts as a failure" 1 "x: a failed in suite s2" --strict x
{ row s0 2 "$head" false false $t1 a; pair s1 "$head" $t2; } | fixture
expect "a failure before the full suite does not count" 0 "suite s1 ($head) is current" --strict x
{ pair s1 "$head" $t1; row s2 2 "$head" true false $t2 a; } | fixture
expect "a failure on a dirty tree does not count" 0 "suite s1 ($head) is current" --strict x
{ pair s1 "$head" $t1; row s2 2 "$off" false false $t2 a; } | fixture
expect "a failure off main does not count" 0 "suite s1 ($head) is current" --strict x
{ pair s1 "$head" $t1; row - null "$head" false false $t2 a; } | fixture
expect "a failing smoke run does not count" 0 "suite s1 ($head) is current" --strict x

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

# config_sha256 absent, null or empty in every row
pair s1 "$head" $t1 | jq -c 'del(.config_sha256)' | fixture
expect "no config hash field" 1 "not counted, missing config_sha256" --strict x
pair s1 "$head" $t1 | jq -c '.config_sha256 = null' | fixture
expect "null config hash" 1 "not counted, missing config_sha256" --strict x
pair s1 "$head" $t1 | jq -c '.config_sha256 = ""' | fixture
expect "empty config hash" 1 "not counted, missing config_sha256" --strict x

# scenario scripts vs suite.txt (lab x has a.sh, b.sh and the helper lib.sh)
pair s1 "$head" $t1 | fixture
expect "scripts match suite.txt" 0 "suite s1 ($head) is current" --strict x
touch lab/x/scenarios/c.sh
expect "script missing from suite.txt" 1 "< c" x
rm lab/x/scenarios/c.sh
printf 'a\nb\nd\n' >lab/x/scenarios/suite.txt
expect "suite.txt name without script" 1 "> d" x
git checkout -q lab/x/scenarios/suite.txt
touch lab/x/scenarios/c.sh lab/x/scenarios/lib-more.sh
printf 'c\n' >lab/x/scenarios/long.txt
expect "long.txt scenario and lib-*.sh helper are not suite members" 0 "suite s1 ($head) is current" --strict x
printf 'a\n' >lab/x/scenarios/long.txt
expect "script not in suite.txt nor long.txt" 1 "< c" x
rm lab/x/scenarios/c.sh lab/x/scenarios/lib-more.sh lab/x/scenarios/long.txt

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
echo 2 >lab/pgha/results/notes.txt
git add lab/pgha/results/notes.txt
git commit -q -m results
expect "change under results/ is ignored" 0 "suite s1 ($p0) is current" --strict pgha
git reset -q --hard "$p0"
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am script
expect "script change fails strict" 1 "lab/pgha/scenarios/a.sh" --strict pgha
git reset -q --hard "$p0"
echo 2 >lab/stage3/grafana/dashboards/d.json
git commit -q -am dash
expect "cross-mounted dashboard changes no scenario" 0 "suite s1 ($p0) is current" --strict pgha
expect "cross-mounted dashboard does not force a rerun with --full" 0 "suite s1 ($p0) is current" --strict --full pgha
git reset -q --hard "$p0"
echo 2 >lab/slice1/grafana/dashboards/d.json
git commit -q -am dash
expect "second cross-mounted dashboard does not force a rerun with --full" 0 "suite s1 ($p0) is current" --strict --full pgha
git reset -q --hard "$p0"

# tiered evidence on pgha: full suite s1 at p0 (a, b), targeted suites after it
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
c1=$(git rev-parse --short HEAD)
{ pair s1 "$p0" $t1; row s2 1 "$c1" false true $t2 a; } | fixture_pgha
expect "targeted suite extends the evidence" 0 "suite s1 ($p0), targeted s2 ($c1: a) is current" --strict pgha
expect "--full ignores targeted suites" 1 "predates changes in 1 files, needs a full suite" --strict --full pgha
expect "--sha prints the evidence commit" 0 "$c1" --sha pgha
pair s1 "$p0" $t1 | fixture_pgha
expect "no targeted suite: scenario still to run" 1 "needs a:" --strict pgha
expect "--sha without targeted suite" 0 "$p0" --sha pgha

{ pair s1 "$p0" $t1; row s2 1 "$c1" false true $t2 b; } | fixture_pgha
expect "targeted suite lacking the affected scenario" 1 "s2: not counted, lacks a" --strict pgha

{ pair s1 "$p0" $t1; row s2 1 "$c1" true true $t2 a; } | fixture_pgha
expect "dirty targeted suite" 1 "s2: not counted, ran on a dirty tree" --strict pgha

git checkout -q -b side2 "$p0"
echo 9 >lab/pgha/side
git add lab/pgha/side
git commit -q -m side2
off2=$(git rev-parse --short HEAD)
git checkout -q main
{ pair s1 "$p0" $t1; row s2 1 "$off2" false true $t2 a; } | fixture_pgha
expect "targeted suite off main" 1 "s2: not counted, $off2 is not on main" --strict pgha

# a full suite on a commit that is off main reports that, not a scenario-set mismatch
# ($off predates the pgha lab, so its suite.txt is empty)
pair s2 "$off" $t2 | fixture_pgha
expect "off-main reason wins over a scenario-set mismatch" 1 "s2: not counted, $off is not on main" --strict pgha
{ pair s1 "$p0" $t1; } | fixture_pgha

# a later full suite off main, or on an unknown commit, does not displace the earlier valid one
{ pair s1 "$p0" $t1; pair s2 "$off2" $t2; } | fixture_pgha
expect "later off-main full suite does not displace" 1 "suite s1 ($p0) predates" --strict pgha
expect "later off-main full suite is reported" 0 "s2: not counted, $off2 is not on main" pgha
{ pair s1 "$p0" $t1; pair s2 deadbeef $t2; } | fixture_pgha
expect "later unknown-commit full suite does not displace" 1 "suite s1 ($p0) predates" --strict pgha
expect "later unknown-commit full suite is reported" 0 "s2: not counted, ran on deadbeef, which is not in this history" pgha

git reset -q --hard "$p0"
echo 3 >lab/pgha/scenarios/lib.sh
git commit -q -am lib
c2=$(git rev-parse --short HEAD)
{ pair s1 "$p0" $t1; row s2 1 "$c2" false true $t2 a; } | fixture_pgha
expect "library change needs a full suite" 1 "needs ALL" --strict pgha
expect "library change: targeted suite not counted" 1 "s2: not counted, changes between $p0 and $c2 need a full suite" --strict pgha

{ pair s1 "$p0" $t1; pair s2 "$c2" $t2; } | fixture_pgha
expect "a later full suite restarts the chain" 0 "suite s2 ($c2) is current" --strict pgha
git reset -q --hard "$p0"

# a targeted suite chains onto an earlier one
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
d1=$(git rev-parse --short HEAD)
echo 2 >lab/pgha/scenarios/b.sh
git commit -q -am "change b"
d2=$(git rev-parse --short HEAD)
{ pair s1 "$p0" $t1; row s2 1 "$d1" false true $t2 a; row s3 1 "$d2" false true "2026-03-01T00:00:00Z" b; } | fixture_pgha
expect "targeted suites chain" 0 "targeted s2 ($d1: a), targeted s3 ($d2: b) is current" --strict pgha
git reset -q --hard "$p0"

# a dashboard-only change between the evidence and a targeted suite is no scenario evidence
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
echo 2 >lab/stage3/grafana/dashboards/d.json
git commit -q -am "dashboard"
f1=$(git rev-parse --short HEAD)
{ pair s1 "$p0" $t1; row s2 1 "$f1" false true $t2 a; } | fixture_pgha
expect "targeted suite counts with a dashboard change in between" 0 "targeted s2 ($f1: a) is current" --strict pgha
git reset -q --hard "$p0"

# version pins: current by default, a change under --full
echo 2 >lab/pgha/versions.sh
git add lab/pgha/versions.sh
git commit -q -m "versions"
pair s1 "$p0" $t1 | fixture_pgha
expect "versions.sh-only change is current by default" 0 "suite s1 ($p0) is current" --strict pgha
expect "versions.sh-only change is stale with --full" 1 "predates changes in 1 files, needs a full suite" --strict --full pgha
git reset -q --hard "$p0"

# a targeted suite on main that is not a descendant of the evidence commit
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
e1=$(git rev-parse --short HEAD)
echo 2 >lab/pgha/scenarios/b.sh
git commit -q -am "change b"
e2=$(git rev-parse --short HEAD)
{ pair s1 "$e2" $t1; row s2 1 "$e1" false true $t2 b; } | fixture_pgha
expect "targeted suite older than the evidence commit" 0 "s2: not counted, $e1 is not a descendant of the evidence commit $e2" pgha
expect "a suite the walk rejects is counted in the verdict" 0 "suite s1 ($e2) is current; 1 later suites not counted" pgha
{ pair s1 "$e2" $t1; row s2 1 "$e1" false true $t2 b; row s3 2 "$e2" true true $t3 a; } | fixture_pgha
expect "summary and walk rejections are counted together" 0 "is current; 2 later suites not counted" pgha

# a targeted suite that started before the full suite does not extend it
{ pair s1 "$p0" $t2; row s0 1 "$e1" false true $t1 a; } | fixture_pgha
expect "targeted suite older than the full suite is ignored" 1 "needs a b:" --strict pgha

# a targeted suite on another configuration than the evidence
{ pair s1 "$p0" $t1; row s2 2 "$e1" false true $t2 a | jq -c '.suite_size = 1 | .config_sha256 = "other"'; } | fixture_pgha
expect "targeted suite with another config hash" 1 "s2: not counted, config_sha256 differs" --strict pgha

# HEAD behind the evidence commit
{ pair s1 "$e2" $t1; } | fixture_pgha
git checkout -q --detach "$p0"
expect "HEAD is not a descendant of the evidence" 1 "s1: not counted, $e2 is not an ancestor of HEAD" --strict pgha
{ pair s1 "$p0" $t1; row s2 2 "$e2" false true $t2 a | jq -c '.suite_size = 2'; row s2 2 "$e2" false true $t2 b; } | fixture_pgha
git checkout -q --detach "$e1"
expect "targeted suite ahead of HEAD is skipped" 1 "s2: not counted, $e2 is not an ancestor of HEAD" --strict pgha
git checkout -q main
git reset -q --hard "$p0"

# a scenario added after the full suite: its own targeted suite completes the evidence
pair s1 "$p0" $t1 | fixture_pgha
printf 'a\nb\nn\n' >lab/pgha/scenarios/suite.txt
touch lab/pgha/scenarios/n.sh
git add lab/pgha/scenarios
git commit -q -m "add n"
n1=$(git rev-parse --short HEAD)
expect "new scenario: the old full suite stays the base" 1 "needs n:" --strict pgha
{ pair s1 "$p0" $t1; row s2 1 "$n1" false true $t2 n; } | fixture_pgha
expect "new scenario: a targeted suite of it is enough" 0 "targeted s2 ($n1: n) is current" --strict pgha
git reset -q --hard "$p0"

# lab-affected.sh: what to run against the current evidence
la="$(cd "$(dirname "$script")" && pwd)/lab-affected.sh"
expectla() {
  local name=$1 want=$2 pat=$3 out rc=0
  shift 3
  out=$(bash "$la" "$@" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && grep -q -F -- "$pat" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc (want $want), pattern '$pat'" >&2
    printf '%s\n' "$out" >&2
    fail=1
  fi
}
pair s1 "$p0" $t1 | fixture_pgha
expectla "lab-affected: nothing to run" 0 "nothing to run" pgha
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
expectla "lab-affected: one scenario" 0 "a" pgha
git reset -q --hard "$p0"
{ pair s1 "$p0" $t1; row s2 2 "$p0" false false $t2 b; } | fixture_pgha
out=$(bash "$la" pgha 2>&1)
if [ "$out" = b ]; then echo "ok   lab-affected: a failed scenario needs a run"; else echo "FAIL lab-affected failed scenario: $out" >&2; fail=1; fi
echo 3 >lab/pgha/scenarios/lib.sh
git commit -q -am lib
out=$(bash "$la" pgha)
if [ "$out" = "$(printf 'a\nb')" ]; then echo "ok   lab-affected: ALL lists suite.txt"; else echo "FAIL lab-affected ALL: $out" >&2; fail=1; fi
git reset -q --hard "$p0"
# ALL puts control last
mkdir -p lab/z/scenarios
printf 'control\na\nb\n' >lab/z/scenarios/suite.txt
touch lab/z/scenarios/control.sh lab/z/scenarios/a.sh lab/z/scenarios/b.sh
git add lab/z
git commit -q -m z
out=$(bash "$la" z 2>/dev/null)
if [ "$out" = "$(printf 'a\nb\ncontrol')" ]; then echo "ok   lab-affected: control last when ALL"; else echo "FAIL lab-affected control: $out" >&2; fail=1; fi
git reset -q --hard "$p0"
# a repository inconsistency fails, it never reads as "nothing to run"
touch lab/pgha/scenarios/c.sh
expectla "lab-affected: inconsistency fails" 1 "check-evidence.sh failed" pgha
rm lab/pgha/scenarios/c.sh
expectla "lab-affected: bad lab" 2 "no lab/nolab/scenarios/suite.txt" nolab

# packs: a change to a pack the lab does not use is current under --full, a used one is not
mkdir -p lab/packs/pk lab/packs/qk
echo 1 >lab/packs/pk/rules.yml
echo 1 >lab/packs/qk/rules.yml
echo '../packs/pk/rules.yml' >lab/pgha/mon.yaml
git add lab/packs lab/pgha/mon.yaml
git commit -q -m packs
q0=$(git rev-parse --short HEAD)
pair s1 "$q0" $t1 | fixture_pgha
echo 2 >lab/packs/qk/rules.yml
git commit -q -am "unused pack"
expect "unused pack change is current with --full" 0 "suite s1 ($q0) is current" --strict --full pgha
git reset -q --hard "$q0"
echo 2 >lab/packs/pk/rules.yml
git commit -q -am "used pack"
expect "used pack change is stale with --full" 1 "needs a full suite" --strict --full pgha
git reset -q --hard "$p0"

# a link target counts as one changed file, whatever number of lines say so
git reset -q --hard "$p0"
rm lab/pgha/scenarios/b.sh
ln -s a.sh lab/pgha/scenarios/b.sh
git add lab/pgha/scenarios
git commit -q -m "b links a"
r0=$(git rev-parse --short HEAD)
pair s1 "$r0" $t1 | fixture_pgha
echo 2 >lab/pgha/scenarios/a.sh
git commit -q -am "change a"
expect "one file, two mapping lines, counted once" 1 "predates changes in 1 files, needs a b" --strict pgha
git reset -q --hard "$p0"

# affected-scenarios.sh failing for a targeted suite: skipped, not stale
tools="$tmp/tools"
mkdir -p "$tools"
cp "$(dirname "$script")"/*.sh "$tools/"
cat >"$tools/affected-scenarios.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = -v ]; then exec bash "$(dirname "$script")/affected-scenarios.sh" "\$@"; fi
exit 1
STUB
{ pair s1 "$p0" $t1; row s2 1 "$p0" false true $t2 a; } | fixture_pgha
out=$(bash "$tools/check-evidence.sh" --strict pgha 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && grep -q "s2: not counted, affected-scenarios.sh failed" <<<"$out" && grep -q "suite s1 ($p0) is current" <<<"$out"; then
  echo "ok   failing affected-scenarios.sh skips the targeted suite"
else
  echo "FAIL failing affected-scenarios.sh: exit $rc" >&2
  printf '%s\n' "$out" >&2
  fail=1
fi

# control runs last in a suite that contains it
git reset -q --hard "$p0"
mkdir -p lab/w/results lab/w/scenarios
printf 'a\nb\ncontrol\n' >lab/w/scenarios/suite.txt
touch lab/w/scenarios/a.sh lab/w/scenarios/b.sh lab/w/scenarios/control.sh
git add lab/w/scenarios
git commit -q -m w
w0=$(git rev-parse --short HEAD)
fixture_w() { cat >lab/w/results/runs.jsonl; }
# wrow START SCENARIO [SIZE]: a clean passing record on w0
wrow() { row s1 "${3:-3}" "$w0" false true "$1" "$2"; }
{ wrow $t1 a; wrow $t2 b; wrow $t3 control; } | fixture_w
expect "control last counts" 0 "suite s1 ($w0) is current" --strict w
{ wrow $t1 a; wrow $t2 control; wrow $t3 b; } | fixture_w
expect "control not last is not counted" 1 "s1: not counted, control did not run last" --strict w
{ wrow $t1 a; wrow $t2 b; wrow $t2 control; } | fixture_w
expect "control at the same start as another record is not last" 1 "s1: not counted, control did not run last" --strict w
{ wrow $t1 a; wrow $t2 b; wrow $t3 control; row s2 2 "$w0" false true 2026-04-01T00:00:00Z control
  row s2 2 "$w0" false true 2026-05-01T00:00:00Z a; } | fixture_w
expect "a targeted suite with control not last is not counted" 0 "s2: not counted, control did not run last" w
git reset -q --hard "$p0"
rm -rf lab/w

expect "missing lab" 1 "no lab/y/results/runs.jsonl" --strict y

exit "$fail"
