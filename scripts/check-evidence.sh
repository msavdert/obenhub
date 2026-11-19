#!/usr/bin/env bash
# Report, per scenario lab, whether its recorded suites still describe the code.
# The base full suite and the targeted suites must have run on a commit that is
# in this history, on main and an ancestor of HEAD; others are reported.
#   check-evidence.sh [--strict] [--full] [--sha] [LAB...]   (default: every lab with results)
# Default (tiered) mode: start from the latest valid full suite, then walk the
# later suites in start order. A later suite counts as a targeted suite when
# it is valid in every respect except that its scenario set is a strict subset
# of suite.txt, its commit is on main and a descendant of the current evidence
# commit (and of HEAD), and it contains every scenario that scripts/affected-scenarios.sh
# names for the changes since that commit (ALL: only a full suite extends). The
# lab is current when nothing is affected between the final evidence commit and
# HEAD; otherwise the scenarios (or ALL) still to run are listed with the files
# that cause them. scripts/lab-affected.sh turns that into a run.
# --full: only a full suite counts, targeted suites are ignored; the lab is
# current when no change since that suite affects it (per affected-scenarios.sh:
# dashboards, rule unit tests, Markdown and packs the lab does not use do not),
# so a rerun is needed after a change that can reach the lab (before a release
# and after a dependency update batch).
# In both modes a failing record of a suite (clean tree, commit on main) that
# started after the full suite makes the lab stale until a targeted suite the
# walk accepts, started after it, passes that scenario, or a later full suite
# replaces the evidence; a scenario no longer in suite.txt is dropped. A failing
# record without a start cannot be ordered: it stays until runs.jsonl is fixed. Every later suite that does not count is
# listed and their number is given in the verdict.
# --sha: print only the evidence commit of each lab, preceded by
# one "failed NAME" line per scenario still failing (scripts/lab-affected.sh).
# A suite counts only if its records have a positive-integer suite_size, one
# record per scenario of the set (lab/<lab>/scenarios/suite.txt for a full
# suite: the full list, one name per line, also read by the lab's mise
# scenarios task), all passed, none ran on a dirty tree, all carry one git_sha
# and one config_sha256, control (when in the set) started after every other
# record, and that commit is on main
# (origin/main, else main; EVIDENCE_MAIN overrides). Records with suite null
# (smoke runs, and rows written before suites existed) are ignored; a suite
# without suite_size is reported as legacy and never counts. Warns by default
# (an unreadable runs.jsonl too); with --strict it exits 1 when a checked
# lab's evidence is missing, unreadable or stale. Needs git and jq; no network.
# Staleness ignores Markdown files and results/ (prose about a suite can only
# be written after it); it also watches the directories a lab's monitoring
# stack mounts from other labs (scripts/evidence-paths.sh). A scenario script missing
# from suite.txt, or a suite.txt name without a script, is a repository
# inconsistency: exit 1 in both modes.
set -euo pipefail
export LC_ALL=C # byte order for the start timestamps compared below
cd "$(git rev-parse --show-toplevel)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/evidence-paths.sh
. "$here/evidence-paths.sh"

strict=0
fullmode=0
shaonly=0
labs=()
for a in "$@"; do
  case "$a" in
    --strict) strict=1 ;;
    --full) fullmode=1 ;;
    --sha) shaonly=1 ;;
    -*) echo "usage: check-evidence.sh [--strict] [--full] [--sha] [LAB...]" >&2; exit 2 ;;
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

if [ "$shaonly" = 1 ]; then
  exec 3>&1 >/dev/null
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
    elif (.pass | not) then "has a failing record"
    elif .dirty then "ran on a dirty tree"
    elif .shas != 1 then "mixed git_sha"
    elif .nohash > 0 then "missing config_sha256"
    elif .hashes != 1 then "mixed config_sha256"
    elif ($bad[.sha] // null) != null then $bad[.sha]
    elif (.set | index("control")) != null and (.ctllast | not) then "control did not run last"
    elif .set == .full or .subset then null
    else "scenario set differs from suite.txt" end;
  map(select(type == "object" and .suite != null)) as $recs | $recs | group_by(.suite)
  | map({suite: .[0].suite, sha: .[0].git_sha, start: (map(.start // "") | min),
         n: length, size: (map(.suite_size) | first),
         nulls: (map(select(.suite_size == null)) | length),
         badsize: any(.[]; .suite_size != null and (.suite_size | posint | not)),
         sizes: (map(.suite_size) | unique | length),
         full: ($fulls[(.[0].git_sha // "")] // []),
         hash: (map(.config_sha256) | first),
         set: (map(.scenario) | unique), distinct: (map(.scenario) | unique | length),
         pass: all(.pass == true), dirty: any(.git_dirty != false),
         shas: (map(.git_sha) | unique | length),
         nohash: (map(select((.config_sha256 // "") == "")) | length),
         hashes: (map(.config_sha256) | unique | length),
         ctllast: ((map(select(.scenario == "control") | .start // "") | max) as $c
                   | all(.[]; .scenario == "control" or (.start // "") < $c))})
  | map(. + {subset: (.set != .full and (.set | length) > 0 and ((.set - .full) | length) == 0)})
  | map(. + {why: why}) | sort_by(.start)
  | (map(select(.why == null and .set == .full)) | last) as $good
  | {good: $good,
     targeted: [.[] | select(.why == null and .subset and ($good == null or .start > $good.start))],
     rejected: [.[] | select(.why != null and ($good == null or .start > $good.start))],
     failed: (if $good == null then [] else
       [$recs[]
        | .start |= (if type == "string" and . != "" then . else "~" end)
        | select(.pass != true and .git_dirty == false and .start > $good.start
                 and (.git_sha | type) == "string" and ($bad[.git_sha] // null) == null)
        | {scenario: (.scenario // "?" | tostring), suite: (.suite | tostring), sha: .git_sha, start}]
       | group_by(.scenario) | map(max_by(.start)) | sort_by(.start) end)}'

stale=0
broken=0
for lab in "${labs[@]}"; do
  runs=lab/$lab/results/runs.jsonl
  # scenario scripts vs suite.txt (run-suite.sh resolves NAME to NAME.sh; lib.sh and lib-*.sh are
  # helpers; the names in an optional long.txt are scenarios kept out of the suite on purpose)
  if [ -f "lab/$lab/scenarios/suite.txt" ]; then
    d=lab/$lab/scenarios
    long=/dev/null
    [ ! -f "$d/long.txt" ] || long="$d/long.txt"
    mism=$(diff <(for f in "$d"/*.sh; do b=${f##*/}; case "$b" in lib.sh | lib-*.sh) ;; *) grep -qxF "${b%.sh}" "$long" || echo "${b%.sh}" ;; esac; done | sort -u) \
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
  # a full suite is the suite.txt of its own commit (a later commit may add scenarios)
  if ! shas=$(jq -s -r '[.[] | select(type == "object") | .git_sha | select(type == "string")] | unique[]' "$runs" 2>/dev/null); then
    echo "$lab: $runs is unreadable (malformed JSON line?)"
    stale=1
    continue
  fi
  # fulls: the suite.txt of each commit named in the records; bad: why a commit
  # cannot carry evidence (not in this history, not on main, not an ancestor of HEAD)
  fulls='{}'
  bad='{}'
  for s in $shas; do
    txt=$(cat "$list")
    why=""
    case "$s" in
      *[!0-9a-f]*) why="ran on $s, which is not in this history" ;;
      *)
        if ! git cat-file -e "$s^{commit}" 2>/dev/null; then
          why="ran on $s, which is not in this history"
        else
          txt=$(git show "$s:$list" 2>/dev/null || true)
          if [ -z "$main" ]; then
            why="no main or origin/main to check $s against"
          elif ! git merge-base --is-ancestor "$s" "$main"; then
            why="$s is not on $main"
          elif ! git merge-base --is-ancestor "$s" HEAD; then
            why="$s is not an ancestor of HEAD"
          fi
        fi
        ;;
    esac
    fulls=$(jq -c --arg s "$s" --arg t "$txt" '. + {($s): ($t | split("\n") | map(select(length > 0)) | unique)}' <<<"$fulls")
    [ -z "$why" ] || bad=$(jq -c --arg s "$s" --arg w "$why" '. + {($s): $w}' <<<"$bad")
  done
  if ! res=$(jq -s --argjson fulls "$fulls" --argjson bad "$bad" "$summarize" "$runs" 2>/dev/null); then
    echo "$lab: $runs is unreadable (malformed JSON line?)"
    stale=1
    continue
  fi
  # every suite after the full one that does not count: from the summary, then from the walk
  nc=0
  notcounted() { echo "$lab: $1: not counted, $2"; nc=$((nc + 1)); }
  while IFS=$'\t' read -r rsuite rwhy; do
    notcounted "$rsuite" "$rwhy"
  done < <(jq -r '.rejected[] | [.suite, .why] | @tsv' <<<"$res")
  # the latest failing record per scenario after the full suite (a missing start counts as latest)
  # fields joined by the unit separator: read does not collapse it, as it does a tab around an empty field
  mapfile -t failed < <(jq -r '.failed[] | [.scenario, .suite, .sha, .start] | join("\u001f")' <<<"$res")
  suite=$(jq -r '.good.suite // empty' <<<"$res")
  sha=$(jq -r '.good.sha // empty' <<<"$res")
  evhash=$(jq -r '.good.hash // empty' <<<"$res")
  # targeted suites: suite, commit, scenarios (space separated), one per line
  mapfile -t targeted < <(jq -r '.targeted[] | [.suite, .sha, .hash, .start, (.set | join(" "))] | @tsv' <<<"$res")
  if [ -z "$suite" ]; then
    for t in "${targeted[@]}"; do
      echo "$lab: ${t%%$'\t'*}: not counted, scenario set differs from suite.txt (no full suite before it)"
    done
    echo "$lab: no complete passing suite recorded"
    stale=1
    continue
  fi
  # walk the targeted suites; the chain commit moves to each one that extends it.
  # With --full the chain is not evidence, but its suites still clear failures.
  ev=$sha
  used=""
  passes=()
  for t in "${targeted[@]}"; do
    IFS=$'\t' read -r tsuite tsha thash tstart tset <<<"$t"
    if ! git merge-base --is-ancestor "$ev" "$tsha"; then
      notcounted "$tsuite" "$tsha is not a descendant of the evidence commit $ev"
      continue
    fi
    if [ "$thash" != "$evhash" ]; then
      notcounted "$tsuite" "config_sha256 differs from the evidence it extends"
      continue
    fi
    if ! need=$("$here/affected-scenarios.sh" "$lab" "$ev" "$tsha"); then
      notcounted "$tsuite" "affected-scenarios.sh failed between $ev and $tsha"
      continue
    fi
    if [ "$need" = ALL ]; then
      notcounted "$tsuite" "changes between $ev and $tsha need a full suite"
      continue
    fi
    missing=""
    for n in $need; do
      case " $tset " in *" $n "*) ;; *) missing="$missing $n" ;; esac
    done
    if [ -n "$missing" ]; then
      notcounted "$tsuite" "lacks${missing} (affected between $ev and $tsha)"
      continue
    fi
    ev=$tsha
    used="$used, targeted $tsuite ($tsha: ${tset// /, })"
    passes+=("$tstart $tset")
  done
  if [ "$fullmode" = 1 ]; then ev=$sha; used=""; fi
  # a failure stays until a chained suite that started after it passed that
  # scenario; a scenario no longer in suite.txt cannot be rerun and is dropped
  still=()
  for f in "${failed[@]}"; do
    IFS=$'\x1f' read -r fname _ _ fstart <<<"$f"
    grep -qxF -- "$fname" "$list" || continue
    cleared=0
    for p in "${passes[@]}"; do
      if [[ "${p%% *}" > "$fstart" ]] && case " ${p#* } " in *" $fname "*) true ;; *) false ;; esac; then cleared=1; fi
    done
    [ "$cleared" = 1 ] || still+=("$f")
  done
  failed=("${still[@]}")
  if [ "$shaonly" = 1 ]; then
    for f in "${failed[@]}"; do echo "failed ${f%%$'\x1f'*}" >&3; done
    echo "$ev" >&3
    continue
  fi
  later=""
  [ "$nc" = 0 ] || later="; $nc later suites not counted"
  for f in "${failed[@]}"; do
    IFS=$'\x1f' read -r fname fsuite fsha fstart <<<"$f"
    echo "$lab: $fname failed in suite $fsuite ($fsha, $fstart) and has not passed in a counted suite since"
    stale=1
  done

  res2=$("$here/affected-scenarios.sh" -v "$lab" "$ev" HEAD 2>&1) || { echo "$lab: affected-scenarios.sh failed: $res2"; stale=1; continue; }
  need=$(grep -v '^  ' <<<"$res2" || true)
  if [ -z "$need" ] && [ "${#failed[@]}" -eq 0 ]; then
    echo "$lab: suite $suite ($sha)$used is current$later"
  elif [ -z "$need" ]; then
    echo "$lab: suite $suite ($sha)$used needs a rerun of the failed scenarios$later"
  else
    why=$(grep '^  ' <<<"$res2" | grep -v ': nothing' || true)
    nfiles=$(awk '{sub(/:$/, "", $1); print $1}' <<<"$why" | sort -u | wc -l)
    if [ "$fullmode" = 1 ]; then need="a full suite"; fi
    echo "$lab: suite $suite ($sha)$used predates changes in $nfiles files, needs ${need//$'\n'/ }$later:"
    echo "$why"
    stale=1
  fi
done

[ "$broken" = 1 ] && exit 1
[ "$strict" = 1 ] && [ "$stale" = 1 ] && exit 1
exit 0
