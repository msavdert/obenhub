#!/usr/bin/env bash
# Report, per scenario lab, whether its latest complete passing suite still
# describes the code: lists the files that changed between the suite's commit
# and HEAD under the lab, lab/packs, lab/scenarios, lab/mon, lab/scripts and
# the lab's extra_paths (directories it mounts from other labs).
#   check-evidence.sh [--strict] [LAB...]     (default: every lab with results)
# A suite counts only if its records have a positive-integer suite_size, one
# record per scenario of lab/<lab>/scenarios/suite.txt (the full list, one name
# per line, also read by the lab's mise scenarios task), all passed, none ran
# on a dirty tree, all carry one git_sha and one config_sha256, and that commit
# is on main
# (origin/main, else main; EVIDENCE_MAIN overrides). Records with suite null
# (smoke runs, and rows written before suites existed) are ignored; a suite
# without suite_size is reported as legacy and never counts. Warns by default
# (an unreadable runs.jsonl too); with --strict it exits 1 when a checked
# lab's evidence is missing, unreadable or stale. Needs git and jq; no network.
# Staleness ignores Markdown files and results/ (prose about a suite can only
# be written after it); it also watches the directories a lab's monitoring
# stack mounts from other labs (extra_paths below). A scenario script missing
# from suite.txt, or a suite.txt name without a script, is a repository
# inconsistency: exit 1 in both modes.
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
  def posint: type == "number" and . > 0 and . == floor;
  def why:
    if .nulls > 0 then "legacy (no suite_size)"
    elif .badsize then "suite_size not a positive integer"
    elif .sizes > 1 then "mixed suite_size"
    elif .n != .size then "partial (\(.n) of \(.size) records)"
    elif .distinct != .n then "duplicate scenario records"
    elif .set != $full then "scenario set differs from suite.txt"
    elif (.pass | not) then "has a failing record"
    elif .dirty then "ran on a dirty tree"
    elif .shas != 1 then "mixed git_sha"
    elif .nohash > 0 then "missing config_sha256"
    elif .hashes != 1 then "mixed config_sha256"
    else null end;
  map(select(type == "object" and .suite != null)) | group_by(.suite)
  | map({suite: .[0].suite, sha: .[0].git_sha, start: (map(.start // "") | min),
         n: length, size: (map(.suite_size) | first),
         nulls: (map(select(.suite_size == null)) | length),
         badsize: any(.[]; .suite_size != null and (.suite_size | posint | not)),
         sizes: (map(.suite_size) | unique | length),
         set: (map(.scenario) | unique), distinct: (map(.scenario) | unique | length),
         pass: all(.pass == true), dirty: any(.git_dirty != false),
         shas: (map(.git_sha) | unique | length),
         nohash: (map(select((.config_sha256 // "") == "")) | length),
         hashes: (map(.config_sha256) | unique | length)})
  | map(. + {why: why}) | sort_by(.start)
  | (map(select(.why == null)) | last) as $good
  | {good: $good,
     rejected: [.[] | select(.why != null and ($good == null or .start > $good.start))]}'

# Directories a lab's monitoring stack mounts from another lab (read from
# lab/pgha/mon/compose.yaml and lab/k8s/mon/compose.yaml; keep in step).
extra_paths() {
  case "$1" in
    pgha) echo lab/stage3/grafana/dashboards lab/slice1/grafana/dashboards ;;
    k8s) echo lab/slice1/grafana/dashboards ;;
  esac
}

stale=0
broken=0
for lab in "${labs[@]}"; do
  runs=lab/$lab/results/runs.jsonl
  # scenario scripts vs suite.txt (run-suite.sh resolves NAME to NAME.sh; lib.sh is the helper)
  if [ -f "lab/$lab/scenarios/suite.txt" ]; then
    d=lab/$lab/scenarios
    mism=$(diff <(for f in "$d"/*.sh; do b=${f##*/}; [ "$b" = lib.sh ] || echo "${b%.sh}"; done | sort -u) \
                <(grep -v '^$' "$d/suite.txt" | sort -u) || true)
    if [ -n "$mism" ]; then
      echo "$lab: $d differs from suite.txt (< script only, > suite.txt only):"
      printf '  %s\n' "${mism//$'\n'/$'\n'  }"
      broken=1
    fi
  fi
  if [ ! -f "$runs" ]; then
    echo "$lab: no $runs"
    stale=1
    continue
  fi
  list=lab/$lab/scenarios/suite.txt
  if [ ! -f "$list" ]; then
    echo "$lab: no $list"
    stale=1
    continue
  fi
  full=$(jq -R -s -c 'split("\n") | map(select(length > 0)) | unique' "$list")
  if ! res=$(jq -s --argjson full "$full" "$summarize" "$runs" 2>/dev/null); then
    echo "$lab: $runs is unreadable (malformed JSON line?)"
    stale=1
    continue
  fi
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
  read -r -a extra <<<"$(extra_paths "$lab")"
  mapfile -t changed < <(git diff --name-only "$sha" HEAD -- "lab/$lab" lab/packs lab/scenarios lab/mon lab/scripts \
    "${extra[@]}" \
    ':(exclude,glob)lab/*/results/**' ':(exclude,glob)**/*.md')
  if [ "${#changed[@]}" -gt 0 ]; then
    echo "$lab: suite $suite ($sha) predates changes in ${#changed[@]} files:"
    printf '  %s\n' "${changed[@]}"
    stale=1
  else
    echo "$lab: suite $suite ($sha) is current"
  fi
done

[ "$broken" = 1 ] && exit 1
[ "$strict" = 1 ] && [ "$stale" = 1 ] && exit 1
exit 0
