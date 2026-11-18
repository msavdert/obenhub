#!/usr/bin/env bash
# Test scripts/affected-scenarios.sh on a fake lab in a throwaway git
# repository: one changed file per case, compared with the expected mapping.
# No docker, no network.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/affected-scenarios.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email t@example.invalid
git config user.name t

d=lab/x/scenarios
mkdir -p $d lab/packs/p/tests lab/packs/p/dashboards lab/packs/q lab/packs/r lab/packs/u lab/x/scripts lab/scenarios/shared $d/impl lab/x/vmalert/rules \
  lab/x/vmalert/tests lab/x/grafana/dashboards lab/x/mon/vmalert/tests lab/x/results \
  lab/other lab/scenarios lab/mon lab/k8s/scenarios
printf 'a\nb\nc\ncontrol\ns\nj\no\nh\ng\ni\nk\n' >$d/suite.txt
printf 'l\nm\nm2\n' >$d/long.txt
for s in a b c control l j o h g i; do printf '#!/bin/sh\n# %s\n' "$s" >$d/$s.sh; done
echo 'lib' >$d/lib.sh
echo shared >lab/scenarios/shared/s.sh
echo shared2 >lab/scenarios/shared/s2.sh
ln -s ../../scenarios/shared/s.sh $d/s.sh
echo real >$d/impl/real.sh
echo only >$d/impl/only-long.sh
ln -s impl/real.sh $d/k.sh
echo real2 >$d/impl/real2.sh
echo unlinked >$d/impl/unlinked.sh
echo chain >$d/impl/chain-real.sh
ln -s chain-real.sh $d/impl/hop.sh
ln -sf impl/hop.sh $d/h.sh
echo oimpl >lab/x/scripts/o-impl.sh
echo chain2 >$d/impl/chain2.sh
ln -sf impl/chain2.sh $d/g.sh
ln -sf g.sh $d/i.sh
ln -sf ../scripts/o-impl.sh $d/o.sh
ln -s impl/real.sh $d/m.sh
ln -s impl/only-long.sh $d/m2.sh
printf '      - ../packs/p:/etc/vmalert/pack:ro\n      - ./vmalert/rules:/etc/vmalert/rules:ro\n' >lab/x/compose.yaml
echo 'cp lab/packs/r/queries.yaml /tmp' >lab/x/scripts/up.sh
echo 'groups: []' >lab/packs/p/rules.yml
echo 'groups: []' >lab/packs/q/rules.yml
echo 'queries' >lab/packs/r/queries.yaml
echo 'groups: []' >lab/packs/u/rules.yml
echo 'groups: []' >lab/x/vmalert/rules/r.yml
echo 'groups: []' >lab/x/mon/vmalert/inventory.yml
for f in lab/packs/p/tests/t.yml lab/x/vmalert/tests/t.yml lab/x/mon/vmalert/tests/t.yml \
  lab/packs/p/dashboards/d.json lab/x/otelcol.yaml \
  lab/x/README.md lab/x/results/runs.jsonl lab/other/f lab/scenarios/guard.sh lab/mon/alertmanager.yml; do
  echo 1 >"$f"
done
echo 'see packs/u' >lab/x/grafana/dashboards/d.json
printf 'a\n' >lab/k8s/scenarios/suite.txt
echo a >lab/k8s/scenarios/a.sh
echo 1 >mise.k8s.toml
echo 1 >mise.toml
git add -A
git commit -q -m base
base=$(git rev-parse HEAD)

fail=0
# case NAME EXPECTED MUTATION...: apply the mutation (a shell command) on top
# of the base commit, commit it, and compare the script's output (one line,
# names joined by spaces; "-" for nothing) with EXPECTED
case_() {
  local name=$1 want=$2 got rc=0
  shift 2
  git reset -q --hard "$base"
  eval "$*"
  git add -A
  git commit -q -m "$name"
  got=$(bash "$script" "${LABN:-x}" "$base" 2>&1) || rc=$?
  got=$(tr '\n' ' ' <<<"$got" | sed 's/ $//')
  [ -n "$got" ] || got=-
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc, got '$got', want '$want'" >&2
    fail=1
  fi
}
# shellcheck disable=SC2329  # called from the eval in case_
chg() { echo changed >>"$1"; }

case_ "markdown" - "chg lab/x/README.md"
case_ "results" - "chg lab/x/results/runs.jsonl"
case_ "other lab, not watched" - "chg lab/other/f"
case_ "scenario script in suite" b "chg $d/b.sh"
case_ "two scenario scripts" "a b" "chg $d/a.sh; chg $d/b.sh"
case_ "long scenario outside the suite" - "chg $d/l.sh"
case_ "scenario script in neither list" ALL "touch $d/z.sh"
case_ "scenario library" ALL "chg $d/lib.sh"
case_ "new library helper" ALL "touch $d/lib-more.sh"
case_ "shared scenario library" ALL "touch lab/scenarios/lib-core.sh"
case_ "shared guard" ALL "chg lab/scenarios/guard.sh"
case_ "suite.txt gains a name" "d" "printf 'a\nb\nc\ncontrol\ns\nj\no\nh\ng\ni\nk\nd\n' >$d/suite.txt; touch $d/d.sh"
case_ "new scenario script and suite.txt line" "d" "printf 'a\nb\nc\ncontrol\ns\nj\no\nh\ng\ni\nk\nd\n' >$d/suite.txt; echo d >$d/d.sh"
case_ "suite.txt loses a name" - "printf 'a\nb\ncontrol\ns\nj\no\nh\ng\ni\nk\n' >$d/suite.txt"
case_ "rule unit test of a pack" - "chg lab/packs/p/tests/t.yml"
case_ "rule unit test of the lab" - "chg lab/x/vmalert/tests/t.yml"
case_ "rule unit test under mon" - "chg lab/x/mon/vmalert/tests/t.yml"
case_ "lab dashboard" - "chg lab/x/grafana/dashboards/d.json"
case_ "pack dashboard" - "chg lab/packs/p/dashboards/d.json"
case_ "pack mounted as a directory" ALL "chg lab/packs/p/rules.yml"
case_ "pack read by a script" ALL "chg lab/packs/r/queries.yaml"
case_ "pack the lab does not use" - "chg lab/packs/q/rules.yml"
case_ "pack the lab starts to use" ALL "chg lab/packs/q/rules.yml; echo ../packs/q >>lab/x/scripts/up.sh"
case_ "lab rule file" ALL "chg lab/x/vmalert/rules/r.yml"
case_ "lab inventory" ALL "chg lab/x/mon/vmalert/inventory.yml"
case_ "unmapped file outside any scenario directory" ALL "chg lab/x/scripts/up.sh"
case_ "collector config" ALL "chg lab/x/otelcol.yaml"
case_ "compose file" ALL "chg lab/x/compose.yaml"
case_ "shared monitoring file" ALL "chg lab/mon/alertmanager.yml"
case_ "scenario and config together" ALL "chg $d/a.sh; chg lab/x/otelcol.yaml"
case_ "scenario deleted and removed from suite.txt" - "git rm -q $d/b.sh; printf 'a\nc\ncontrol\ns\nj\no\nh\ng\ni\nk\n' >$d/suite.txt"
case_ "scenario deleted but still in suite.txt" ALL "git rm -q $d/b.sh"
case_ "scenario moved to long.txt" - "printf 'a\nb\ncontrol\ns\nj\no\nh\ng\ni\nk\n' >$d/suite.txt; echo c >>$d/long.txt; chg $d/c.sh"
case_ "long.txt edited" - "echo n >>$d/long.txt"
case_ "link target changes every suite scenario linking to it" k "chg $d/impl/real.sh"
case_ "link target only linked from a long scenario" ALL "chg $d/impl/only-long.sh"
case_ "link resolved at BASE" k "rm $d/k.sh; echo plain >$d/k.sh; chg $d/impl/real.sh"
case_ "link resolved at HEAD" j "rm $d/j.sh; ln -s impl/real2.sh $d/j.sh; chg $d/impl/real2.sh"
case_ "link target outside scenarios/" ALL "chg lab/x/scripts/o-impl.sh"
case_ "script in a subdirectory that no link points at" ALL "chg $d/impl/unlinked.sh"
case_ "link chain, final target" ALL "chg $d/impl/chain-real.sh"
case_ "link chain through a scenario link" ALL "chg $d/impl/chain2.sh"
case_ "link chain, middle link retargeted" ALL "ln -sf real.sh $d/impl/hop.sh"
case_ "pack used at BASE only" ALL "chg lab/packs/u/rules.yml; echo none >lab/x/grafana/dashboards/d.json"
case_ "pack used at BASE and HEAD" ALL "chg lab/packs/u/rules.yml"
case_ "scenario symlink target in the shared dir" ALL "chg lab/scenarios/shared/s.sh"
case_ "scenario symlink retargeted" s "ln -sf ../../scenarios/shared/s2.sh $d/s.sh"
LABN=k8s case_ "mise.k8s.toml is watched by k8s" ALL "chg mise.k8s.toml"
LABN=k8s case_ "mise.toml is not watched" - "chg mise.toml"
case_ "mise.k8s.toml is not watched by other labs" - "chg mise.k8s.toml"
# a rename shows both paths, whatever diff.renames says
case_ "config moved into a tests directory" ALL "git mv lab/x/otelcol.yaml lab/x/vmalert/tests/otelcol.yaml"
git config diff.renames true
case_ "config moved into a tests directory, diff.renames on" ALL "git mv lab/x/otelcol.yaml lab/x/vmalert/tests/otelcol.yaml"
git config --unset diff.renames

git reset -q --hard "$base"
# rc_is NAME WANT ARGS...: the script's exit code on bad input
rc_is() {
  local name=$1 want=$2 rc=0
  shift 2
  bash "$script" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc, want $want" >&2
    fail=1
  fi
}
rc_is "same commit, nothing" 0 x "$base" "$base"
rc_is "too few arguments" 2 x
rc_is "bad lab name" 2 'x y' "$base"
rc_is "unknown commit" 1 x nosuchcommit
rc_is "lab without suite.txt" 2 nolab "$base"

exit "$fail"
