#!/usr/bin/env bash
# The scenarios of a lab that need a run against its current evidence.
#   lab-affected.sh [--run] LAB
# Evidence commit: the end of check-evidence.sh's chain (latest full suite plus
# the targeted suites after it); no valid full suite means ALL. Prints the
# scenarios in suite.txt order with control last, or ALL's whole suite.txt, or
# "nothing to run". With --run it executes them as one suite through
# lab/scenarios/run-suite.sh (k8s through MISE_ENV=k8s mise exec --).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run=0
if [ "${1:-}" = "--run" ]; then run=1; shift; fi
[ "$#" -eq 1 ] || { echo "usage: lab-affected.sh [--run] LAB" >&2; exit 2; }
lab=$1
case "$lab" in *[!a-z0-9]* | "") echo "bad lab name: $lab" >&2; exit 2 ;; esac
list=lab/$lab/scenarios/suite.txt
[ -f "$list" ] || { echo "no $list" >&2; exit 2; }

if ! ev=$("$here/check-evidence.sh" --sha "$lab" 2>/dev/null); then
  echo "check-evidence.sh failed for $lab (a repository inconsistency; run it to see which)" >&2
  exit 1
fi
ev=$(tail -n 1 <<<"$ev")
if [ -z "$ev" ]; then
  echo "no valid full suite for $lab: everything needs a run" >&2
  need=ALL
else
  need=$("$here/affected-scenarios.sh" "$lab" "$ev" HEAD)
fi

# suite.txt order, control last
todo=()
while IFS= read -r n; do
  [ -n "$n" ] && [ "$n" != control ] || continue
  if [ "$need" = ALL ] || grep -qxF -- "$n" <<<"$need"; then todo+=("$n"); fi
done <"$list"
if grep -qx control "$list" && { [ "$need" = ALL ] || grep -qx control <<<"$need"; }; then todo+=(control); fi

if [ "${#todo[@]}" -eq 0 ]; then
  echo "nothing to run"
  exit 0
fi
printf '%s\n' "${todo[@]}"
[ "$run" = 1 ] || exit 0

if [ "$lab" = k8s ]; then
  MISE_ENV=k8s exec mise exec -- lab/scenarios/run-suite.sh "$lab" "${todo[@]}"
fi
exec lab/scenarios/run-suite.sh "$lab" "${todo[@]}"
