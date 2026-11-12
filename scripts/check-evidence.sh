#!/usr/bin/env bash
# Report, per scenario lab, whether its latest complete passing suite still
# describes the code: lists the files under the lab, lab/packs and
# lab/scenarios that changed between the suite's commit and HEAD.
#   check-evidence.sh [--strict] [LAB...]     (default: every lab with results)
# A suite counts only if it has suite_size records, all passed, none ran on a
# dirty tree, all carry one git_sha, and that commit is on main (origin/main,
# else main; EVIDENCE_MAIN overrides). Suites without suite_size are legacy
# and never count. Warns by default; with --strict it exits 1 when a checked
# lab's evidence is missing or stale. Needs git and jq; no network.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

strict=0
labs=()
for a in "$@"; do
  case "$a" in
    --strict) strict=1 ;;
    -*) echo "usage: check-evidence.sh [--strict] [LAB...]" >&2; exit 2 ;;
    *) labs+=("$a") ;;
  esac
done
if [ "${#labs[@]}" -eq 0 ]; then
  for runs in lab/*/results/runs.jsonl; do
    [ -e "$runs" ] || continue
    l=${runs#lab/}
    labs+=("${l%%/*}")
  done
fi

main=${EVIDENCE_MAIN:-}
if [ -z "$main" ]; then
  for c in origin/main main; do
    git rev-parse --verify -q "$c^{commit}" >/dev/null && { main=$c; break; }
  done
fi

# One object per run of the file: the latest valid suite and why others were
# rejected. Fields are named, so the record layout does not matter.
# shellcheck disable=SC2016  # jq program, not shell
summarize='
  def why:
    if .size == null then "legacy (no suite_size)"
    elif .n != .size then "partial (\(.n) of \(.size) records)"
    elif .sizes > 1 then "mixed suite_size"
    elif (.pass | not) then "has a failing record"
    elif .dirty then "ran on a dirty tree"
    elif .shas != 1 then "mixed git_sha"
    else null end;
  map(select(.suite != null)) | group_by(.suite)
  | map({suite: .[0].suite, sha: .[0].git_sha, start: (map(.start // "") | min),
         n: length, size: (map(.suite_size) | first),
         sizes: (map(.suite_size) | unique | length),
         pass: all(.pass == true), dirty: any(.git_dirty != false),
         shas: (map(.git_sha) | unique | length)})
  | map(. + {why: why}) | sort_by(.start)
  | (map(select(.why == null)) | last) as $good
  | {good: $good,
     rejected: [.[] | select(.why != null and ($good == null or .start > $good.start))]}'

stale=0
for lab in "${labs[@]}"; do
  runs=lab/$lab/results/runs.jsonl
  if [ ! -f "$runs" ]; then
    echo "$lab: no $runs"
    stale=1
    continue
  fi
  res=$(jq -s "$summarize" "$runs")
  jq -r '.rejected[] | "\(.suite): not counted, \(.why)"' <<<"$res" | sed "s/^/$lab: /"
  suite=$(jq -r '.good.suite // empty' <<<"$res")
  sha=$(jq -r '.good.sha // empty' <<<"$res")
  if [ -z "$suite" ]; then
    echo "$lab: no complete passing suite recorded"
    stale=1
    continue
  fi
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "$lab: suite $suite ran on $sha, which is not in this history"
    stale=1
    continue
  fi
  if [ -z "$main" ]; then
    echo "$lab: suite $suite ($sha): no main or origin/main to check it against"
    stale=1
    continue
  elif ! git merge-base --is-ancestor "$sha" "$main"; then
    echo "$lab: suite $suite ($sha) is not on $main"
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
done

[ "$strict" = 1 ] && [ "$stale" = 1 ] && exit 1
exit 0
