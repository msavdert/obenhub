#!/usr/bin/env bash
# Test scripts/affected-scenarios.sh on a fake lab in a throwaway git
# repository: one changed file per case, compared with the expected mapping.
# Then derives the cross-lab Compose mounts of the real repository and compares
# them with evidence_extra_paths. No docker, no network. Needs yq.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/affected-scenarios.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email t@example.invalid
git config user.name t

d=lab/x/scenarios
mkdir -p $d packs/p/tests packs/p/dashboards packs/q/dashboards packs/r packs/u lab/x/scripts lab/scenarios/shared $d/impl lab/x/vmalert/rules \
  lab/x/vmalert/tests lab/x/grafana/dashboards lab/x/mon/vmalert/tests lab/x/results \
  lab/other lab/scenarios lab/mon lab/k8s/scenarios
printf 'a\nb\nc\ncontrol\ns\nj\no\nh\ng\ni\nk\n' >$d/suite.txt
printf 'l\nm\nm2\nln\n' >$d/long.txt
for s in a b c control l j o h g i; do printf '#!/bin/sh\n# %s\n' "$s" >$d/$s.sh; done
printf '#!/bin/sh\nEXPECT="LabAlert"\n' >$d/a.sh
printf 'lib\n# GammaLib and FooBar are allowed here\n' >$d/lib.sh
# scenarios naming alerts: b and c directly, s through its symlink, l is long
printf '#!/bin/sh\n# b\nEXPECT="AlphaDown"\n' >$d/b.sh
printf '#!/bin/sh\n# c\n# covers Zeta\nALLOW="AlphaDown BetaHigh"\n' >$d/c.sh
printf '#!/bin/sh\n# FooBar only\ncat <<E\n#!/bin/sh\nE\n' >$d/j.sh
printf '#!/bin/sh\n# l\nEXPECT="AlphaDown"\n' >$d/l.sh
printf '#!/bin/sh\nEXPECT="BetaHigh"\n' >lab/scenarios/shared/s.sh
echo longonly >lab/scenarios/shared/longonly.sh
echo k8sonly >lab/scenarios/shared/k8sonly.sh
echo orphan >lab/scenarios/shared/orphan.sh
ln -s ../../scenarios/shared/longonly.sh $d/ln.sh
ln -s ../../scenarios/shared/k8sonly.sh lab/k8s/scenarios/z.sh
echo versions >lab/x/versions.sh
echo recv >packs/p/upstream-receiver-metrics.txt
echo d >packs/q/dashboards/d.json
cat >packs/p/rules.yml <<'YML'
groups:
  - name: g1
    interval: 30s
    rules:
      - alert: AlphaDown
        expr: up == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: alpha
      - alert: BetaHigh
        expr: x > 1
      - alert: GammaLib
        expr: y > 1
      - alert: Foo
        expr: f > 1
      - alert: Zeta
        expr: zz > 1
      - record: rec:one
        expr: sum(x)
YML
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
printf '      - ../../packs/p:/etc/vmalert/pack:ro\n      - ./vmalert/rules:/etc/vmalert/rules:ro\n' >lab/x/compose.yaml
echo 'cp packs/r/queries.yaml /tmp' >lab/x/scripts/up.sh
echo 'groups: []' >packs/q/rules.yml
echo 'queries' >packs/r/queries.yaml
echo 'groups: []' >packs/u/rules.yml
printf 'groups:\n  - name: lg\n    interval: 15s\n    rules:\n      - alert: LabAlert\n        expr: 1\n' >lab/x/vmalert/rules/r.yml
echo 'groups: []' >lab/x/mon/vmalert/inventory.yml
for f in packs/p/tests/t.yml lab/x/vmalert/tests/t.yml lab/x/mon/vmalert/tests/t.yml \
  packs/p/dashboards/d.json packs/p/otelcol.yaml packs/otelcol-base.yaml \
  lab/x/README.md lab/x/results/runs.jsonl lab/other/f lab/scenarios/guard.sh lab/scenarios/test-guard.sh lab/scenarios/test-stub.py lab/mon/alertmanager.yml; do
  echo 1 >"$f"
done
printf 'receivers:\n  x: 1\n' >lab/x/otelcol.yaml
echo 'see packs/u' >lab/x/grafana/dashboards/d.json
printf 'a\n' >lab/k8s/scenarios/suite.txt
echo a >lab/k8s/scenarios/a.sh
printf '[tools]\nkind = "1"\n' >mise.k8s.toml
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
  # shellcheck disable=SC2086  # FLAGS is a word list such as -f
  got=$(bash "$script" ${FLAGS:-} "${LABN:-x}" "$base" 2>&1) || rc=$?
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
case_ "rule unit test of a pack" - "chg packs/p/tests/t.yml"
case_ "rule unit test of the lab" - "chg lab/x/vmalert/tests/t.yml"
case_ "rule unit test under mon" - "chg lab/x/mon/vmalert/tests/t.yml"
case_ "harness self-test script" - "chg lab/scenarios/test-guard.sh"
case_ "harness self-test stub" - "chg lab/scenarios/test-stub.py"
case_ "lab dashboard" PANELS "chg lab/x/grafana/dashboards/d.json"
case_ "pack Collector fragment, pack used" - "chg packs/p/otelcol.yaml"
case_ "pack Collector base" - "chg packs/otelcol-base.yaml"
case_ "pack dashboard, pack used" PANELS "chg packs/p/dashboards/d.json"
case_ "pack dashboard, pack not used" - "chg packs/q/dashboards/d.json"
case_ "pack mounted as a directory" ALL "chg packs/p/rules.yml"
case_ "pack read by a script" ALL "chg packs/r/queries.yaml"
case_ "pack the lab does not use" - "chg packs/q/rules.yml"
case_ "pack the lab starts to use" ALL "chg packs/q/rules.yml; echo ../../packs/q >>lab/x/scripts/up.sh"
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
case_ "pack used at BASE only" "ALL PANELS" "chg packs/u/rules.yml; echo none >lab/x/grafana/dashboards/d.json"
case_ "pack used at BASE and HEAD" ALL "chg packs/u/rules.yml"
case_ "scenario symlink target in the shared dir" s "chg lab/scenarios/shared/s.sh"
case_ "scenario symlink retargeted" s "ln -sf ../../scenarios/shared/s2.sh $d/s.sh"
# comments, formatting, versions
case_ "versions.sh" - "chg lab/x/versions.sh"
FLAGS=-f case_ "versions.sh, full mode" ALL "chg lab/x/versions.sh"
case_ "upstream-receiver-metrics.txt" - "chg packs/p/upstream-receiver-metrics.txt"
case_ "comment-only YAML" - "echo '# note' >>lab/x/otelcol.yaml"
case_ "formatting-only YAML" - "printf 'receivers: {x: 1}\n' >lab/x/otelcol.yaml"
case_ "YAML value changed" ALL "printf 'receivers:\n  x: 2\n' >lab/x/otelcol.yaml"
case_ "comment-only scenario script" - "printf '\n  # more\n' >>$d/a.sh"
case_ "comment-only lib.sh" - "printf '# more\n\n' >>$d/lib.sh"
case_ "shebang changed" a "sed -i '1s|.*|#!/bin/bash|' $d/a.sh"
case_ "shebang line added" a "sed -i '1i #!/bin/bash' $d/a.sh"
case_ "script made executable" a "chmod +x $d/a.sh"

# alert rules (pack p is used by the lab; AlphaDown is named by b, c and the long l;
# BetaHigh by c and by s through its symlink; GammaLib only in lib.sh)
rules=packs/p/rules.yml
# alert_edit SED...: edit the pack rules with sed
# shellcheck disable=SC2329  # called from the eval in case_
alert_edit() { sed -i "$@" "$rules"; }
case_ "alert expr changed" "b c control" "alert_edit 's/up == 0/up == 1/'"
case_ "alert for changed" "b c control" "alert_edit 's/for: 1m/for: 2m/'"
case_ "alert label changed" "b c control" "alert_edit 's/severity: warning/severity: critical/'"
case_ "alert named by a symlinked scenario" "c control s" "alert_edit 's/x > 1/x > 2/'"
# an alerting config file (its bytes are in config_sha256) always maps at least to control
case_ "alert annotation only" control "alert_edit 's/summary: alpha/summary: beta/'"
case_ "alert comment only" control "alert_edit '1i # a comment'"
case_ "lab inventory comment only" control "echo '# c' >>lab/x/mon/vmalert/inventory.yml"
case_ "alertmanager.yml comment only" control "echo '# c' >>lab/mon/alertmanager.yml"
case_ "rules comment only, pack the lab does not use" - "echo '# c' >>packs/q/rules.yml"
case_ "alert group interval changed" "ALL" "alert_edit 's/interval: 30s/interval: 60s/'"
case_ "group renamed, it also holds a recording rule" ALL "alert_edit 's/name: g1/name: g2/'"
case_ "alert named only as a longer word (scenario and lib)" control "alert_edit 's/f > 1/f > 2/'"
case_ "scenario text read at BASE" "c control" "sed -i '/alert: Zeta/,+1d' $rules; sed -i '/covers Zeta/d' $d/c.sh"
case_ "heredoc shebang changed" j "sed -i '4s|.*|#!/bin/bash|' $d/j.sh"
case_ "alert added" "control" "printf '      - alert: NewOne\n        expr: z > 1\n' >>$rules"
case_ "alert added, named by a scenario" "b c control" "printf '      - alert: AlphaDown\n        expr: z > 1\n' >>$rules"
case_ "alert deleted" "b c control" "sed -i '/alert: AlphaDown/,/summary: alpha/d' $rules"
case_ "recording rule changed" ALL "alert_edit 's/sum(x)/sum(y)/'"
case_ "alert named in lib.sh" ALL "alert_edit 's/y > 1/y > 2/'"
case_ "unparsable rules" ALL "printf 'groups: [\n' >$rules"
case_ "rules file deleted" ALL "git rm -q -f $rules"
case_ "rules file added" control "printf 'groups:\n - name: n\n   rules:\n    - alert: Fresh\n      expr: 1\n' >lab/x/vmalert/rules/new.yml"
case_ "pack rules, pack not used" - "sed -i 's/expr: .*/expr: 1/' packs/q/rules.yml; printf 'groups:\n - name: g\n   rules:\n    - alert: Q\n      expr: 1\n' >packs/q/rules.yml"
case_ "lab rule file, group moved" "a control" "sed -i 's/name: lg/name: lg2/' lab/x/vmalert/rules/r.yml"
case_ "lab rule file, alert replaced" "a control" "printf 'groups:\n - name: g\n   rules:\n    - alert: LabNew\n      expr: 1\n' >lab/x/vmalert/rules/r.yml"
case_ "inventory, recording rule" ALL "printf 'groups:\n - name: g\n   rules:\n    - record: r\n      expr: 1\n' >lab/x/mon/vmalert/inventory.yml"

# shared scenarios
case_ "shared scenario linked only from a long scenario" - "chg lab/scenarios/shared/longonly.sh"
case_ "shared scenario linked only from another lab" - "chg lab/scenarios/shared/k8sonly.sh"
LABN=k8s case_ "shared scenario linked from this lab, not in its suite" - "chg lab/scenarios/shared/k8sonly.sh"
case_ "shared scenario linked from nowhere" ALL "chg lab/scenarios/shared/orphan.sh"
LABN=k8s case_ "mise.k8s.toml is watched by k8s" ALL "chg mise.k8s.toml"
LABN=k8s case_ "comment-only TOML" - "printf '# note\\n\\n' >>mise.k8s.toml"
LABN=k8s case_ "formatting-only TOML" - "printf 'tools = {kind = \"1\"}\\n' >mise.k8s.toml"
LABN=k8s case_ "TOML value changed" ALL "sed -i 's/\"1\"/\"2\"/' mise.k8s.toml"
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

# The cross-lab Compose mounts of the real repository against evidence_extra_paths.
# Dependencies that are not Compose mounts, with the reason:
#   k8s     mise.k8s.toml    pins the k8s tools (MISE_ENV=k8s)
#   oracle  lab/pgha/versions.sh   sourced by lab/oracle/scripts/collector.sh
#   oracle  lab/pgha/lab-config.sh sourced by the oracle scripts and scenarios/lib.sh
declare -A nonmount=([k8s]="mise.k8s.toml" [oracle]="lab/pgha/versions.sh lab/pgha/lab-config.sh")
# shellcheck source=scripts/evidence-paths.sh
. "$repo/scripts/evidence-paths.sh"
# mount_sources FILE: bind-mount sources (short and long syntax) and config and
# secret files of a Compose file, as written
mount_sources() {
  yq -r '(.services[].volumes[]? | (select(tag == "!!str") | split(":") | .[0]), (select(tag == "!!map") | .source)), ((.configs // {}) + (.secrets // {}) | .[] | .file)' "$1" 2>/dev/null | grep -v '^null$' || true
}
mounts_fail=0
declare -A seen_lab=()
while IFS= read -r cf; do
  rel=${cf#"$repo/"}
  L=${rel#lab/}
  L=${L%%/*}
  case "$L" in mon | scenarios | scripts) continue ;; esac
  seen_lab[$L]=1
  mapfile -t extra < <(evidence_extra_paths "$L" | tr ' ' '\n' | grep -v '^$' || true)
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    p=$(realpath -m -s --relative-to="$repo" "$(dirname "$cf")/$m")
    case "$p" in lab/*) ;; *) continue ;; esac
    O=${p#lab/}
    O=${O%%/*}
    case "$O" in "$L" | mon | scenarios | scripts) continue ;; esac
    ok=0
    for e in "${extra[@]}"; do
      case "$p" in "$e" | "$e"/*) ok=1 ;; esac
    done
    echo "$p" >>"$tmp/derived.$L"
    if [ "$ok" = 1 ]; then
      echo "ok   $rel mounts $p, in evidence_extra_paths $L"
    else
      echo "FAIL $rel mounts $p, which evidence_extra_paths $L does not cover" >&2
      mounts_fail=1
    fi
  done < <(mount_sources "$cf")
done < <(find "$repo/lab" -name 'compose*.y*ml' -not -path '*/node_modules/*' | sort)
# every extra path is derived from a mount or is a listed non-Compose dependency
declare -A done_lab=()
for L in "${!seen_lab[@]}" "${!nonmount[@]}"; do
  [ -z "${done_lab[$L]:-}" ] || continue
  done_lab[$L]=1
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case " ${nonmount[$L]:-} " in *" $e "*) :;; *) false;; esac && { echo "ok   evidence_extra_paths $L: $e (allow-listed, not a Compose mount)"; continue; }
    if [ -f "$tmp/derived.$L" ] && awk -v e="$e" 'index($0, e "/") == 1 || $0 == e {f=1} END {exit !f}' "$tmp/derived.$L"; then
      echo "ok   evidence_extra_paths $L: $e (derived from a Compose mount)"
    else
      echo "FAIL evidence_extra_paths $L lists $e: no Compose mount of lab/$L leads there and it is not in the allow-list of this test" >&2
      mounts_fail=1
    fi
  done < <(evidence_extra_paths "$L" | tr ' ' '\n')
done
# and every allow-listed path is still in evidence_extra_paths
for L in "${!nonmount[@]}"; do
  read -r -a entries <<<"${nonmount[$L]}"
  for e in "${entries[@]}"; do
    case " $(evidence_extra_paths "$L") " in
      *" $e "*) echo "ok   allow-list $L: $e is in evidence_extra_paths" ;;
      *) echo "FAIL allow-list $L: $e is not in evidence_extra_paths $L" >&2; mounts_fail=1 ;;
    esac
  done
done
[ "$mounts_fail" = 0 ] || fail=1

exit "$fail"
