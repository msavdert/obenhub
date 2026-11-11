#!/usr/bin/env bash
# Report, per scenario lab, whether its latest passing suite still describes
# the code: lists the files under the lab, lab/packs and lab/scenarios that
# changed between the suite's commit and HEAD. Warns by default; with
# --strict it exits 1 when any lab's evidence is missing or stale (for use
# before a release). Needs git and jq; no network, no running lab.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

strict=0
[ "${1:-}" = --strict ] && strict=1
stale=0

for runs in lab/*/results/runs.jsonl; do
  lab=${runs#lab/}
  lab=${lab%%/*}
  # latest suite whose every record passed
  read -r suite sha < <(jq -rs '
    map(select(.suite != null)) | group_by(.suite)
    | map(select(all(.pass)) | {suite: .[0].suite, sha: .[0].git_sha, start: (map(.start) | min)})
    | sort_by(.start) | last // empty | "\(.suite) \(.sha)"' "$runs") || true
  if [ -z "${suite:-}" ]; then
    echo "$lab: no passing suite recorded"
    stale=1
    continue
  fi
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "$lab: suite $suite ran on $sha, which is not in this history"
    stale=1
    continue
  fi
  mapfile -t changed < <(git diff --name-only "$sha" HEAD -- "lab/$lab" lab/packs lab/scenarios \
    ':(exclude,glob)lab/*/results/**')
  if [ "${#changed[@]}" -gt 0 ]; then
    echo "$lab: suite $suite ($sha) predates changes in ${#changed[@]} files:"
    printf '  %s\n' "${changed[@]}"
    stale=1
  else
    echo "$lab: suite $suite ($sha) is current"
  fi
  unset suite sha
done

[ "$strict" = 1 ] && [ "$stale" = 1 ] && exit 1
exit 0
