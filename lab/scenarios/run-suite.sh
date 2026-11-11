#!/usr/bin/env bash
# Run a list of fault scenarios of one lab as a suite, in the order given,
# stopping at the first failure.
#   lab/scenarios/run-suite.sh LAB SCENARIO...      (LAB: slice1, stage3, pgha, k8s)
# Refuses to start when the tree has changes outside lab/*/results/ (the
# records carry git_sha, so they must describe a commit) or when another run,
# of any lab, holds the host-wide lock (suites in different labs would share
# the host and their timings would not be independent). Exports SUITE_ID,
# which every record of the suite carries.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/scenarios/guard.sh
. "$here/guard.sh"

[ "$#" -ge 2 ] || { echo "usage: run-suite.sh LAB SCENARIO..." >&2; exit 2; }
lab=$1; shift
case "$lab" in *[!a-z0-9]*|"") echo "bad lab name: $lab" >&2; exit 2;; esac
dir="$GUARD_TOP/lab/$lab/scenarios"
[ -d "$dir" ] || { echo "no such lab: $lab" >&2; exit 2; }
for s in "$@"; do
  case "$s" in *[!a-z-]*|lib|"") echo "bad scenario name: $s" >&2; exit 2;; esac
  [ -x "$dir/$s.sh" ] || { echo "no such scenario in $lab: $s" >&2; exit 2; }
done

dirty=$(dirty_paths) || { echo "refusing to start: cannot tell whether the tree is clean" >&2; exit 1; }
if [ -n "$dirty" ]; then
  echo "refusing to start: the tree has changes outside lab/*/results/ (commit or stash them):" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

SUITE_ID="$lab-$(date -u +%Y%m%dT%H%M%SZ)-$(git_sha)"
export SUITE_ID
lock_acquire "$SUITE_ID" || { echo "refusing to start: another lab run holds $SUITE_LOCK_FILE" >&2; exit 1; }
echo "suite $SUITE_ID: $*"

n=0 passed=0
for s in "$@"; do
  n=$((n + 1))
  echo "=== $s ($n/$#)"
  # fd 9 is the lock: closed for the scenario so its background children cannot keep it
  if "$dir/$s.sh" 9>&-; then
    passed=$((passed + 1))
  else
    echo "suite $SUITE_ID: FAILED at $s; $passed of $# passed, $(($# - n)) not run" >&2
    exit 1
  fi
done
echo "suite $SUITE_ID: $passed of $# passed"
