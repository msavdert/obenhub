#!/usr/bin/env bash
# Which scenarios of a lab must run again because of the changes between two
# commits: their names, one per line, sorted, or the single line ALL.
#   affected-scenarios.sh [-v] LAB BASE [HEAD]      (HEAD defaults to HEAD)
# Looks at the files check-evidence.sh watches (scripts/evidence-paths.sh;
# renames count as a delete plus an add) and maps each changed file:
#   Markdown, results/, rule unit tests, Grafana dashboards      nothing
#   scenarios/<name>.sh in the lab's suite.txt                   that scenario, and every
#                                                                suite scenario whose symlink
#                                                                (at BASE or HEAD) points at it
#   scenarios/<name>.sh in long.txt, or deleted (it was in       nothing
#     suite.txt or long.txt at BASE), and long.txt itself
#   scenarios/suite.txt                                          names added at HEAD
#   a file of lab/packs/<p> (not tests or dashboards)            ALL if the lab uses the
#                                                                pack, else nothing
#   every other watched file: lib.sh and lib-*.sh, the shared    ALL
#     lab/scenarios files (and the scripts the lab's scenario
#     symlinks point at), lab/mon, lab/scripts, vmalert rules
#     and inventories, compose files, configs, queries, scripts
# A lab uses pack <p> when a non-Markdown file under lab/<lab> outside results/
# mentions the string packs/<p> at BASE or HEAD (a compose mount of a file or
# of the directory, a script that reads the queries). Only lab/<lab> is
# searched; changes under lab/mon and lab/scripts are ALL themselves.
# -v also prints, to stderr, what each changed file maps to.
# Exit 2 on bad arguments, 1 on git errors. Needs git, grep, awk.
set -euo pipefail

verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: affected-scenarios.sh [-v] LAB BASE [HEAD]" >&2
  exit 2
fi
lab=$1 base=$2 head=${3:-HEAD}
case "$lab" in *[!a-z0-9]* | "") echo "bad lab name: $lab" >&2; exit 2 ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/evidence-paths.sh
. "$here/evidence-paths.sh"
cd "$(git rev-parse --show-toplevel)" || exit 1
for c in "$base" "$head"; do
  git rev-parse --verify -q "$c^{commit}" >/dev/null || { echo "not a commit: $c" >&2; exit 1; }
done

list=lab/$lab/scenarios/suite.txt
# show REV PATH: the file at REV, empty when it does not exist there
show() { git cat-file -e "$1:$2" 2>/dev/null && git show "$1:$2" || true; }
suite=$(show "$head" "$list" | grep -v '^$' || true)
if [ -z "$suite" ]; then
  echo "no $list at $head" >&2
  exit 2
fi
longlist=lab/$lab/scenarios/long.txt
long=$(show "$head" "$longlist")
suite_b=$(show "$base" "$list")
long_b=$(show "$base" "$longlist")

evidence_pathspec "$lab"
mapfile -t changed < <(git diff --no-renames --name-only "$base" "$head" -- "${EVIDENCE_SPEC[@]}") || exit 1

all=0
declare -A names=()
has() { grep -qxF -- "$2" <<<"$1"; }

# uses PACK: does a file of the lab mention packs/PACK at BASE or HEAD
uses() {
  local rev
  for rev in "$base" "$head"; do
    git grep -I -q -F -e "packs/$1" "$rev" -- "lab/$lab" ':(exclude,glob)**/*.md' \
      ':(exclude,glob)lab/*/results/**' 2>/dev/null && return 0
  done
  return 1
}

# links REV: "target<TAB>source" for every symlink under the lab's scenarios/
# at REV whose target is another file under scenarios/
links() {
  local meta path mode blob tgt
  while IFS=$'\t' read -r meta path; do
    # shellcheck disable=SC2086  # split "mode type blob"
    set -- $meta
    mode=$1 blob=$3
    [ "$mode" = 120000 ] || continue
    tgt=$(git cat-file -p "$blob")
    tgt=$(realpath -m -s --relative-to=. "${path%/*}/$tgt")
    case "$tgt" in "lab/$lab/scenarios/"*) printf '%s\t%s\n' "$tgt" "$path" ;; esac
  done < <(git ls-tree -r "$1" -- "lab/$lab/scenarios")
}
declare -A linked=()   # target -> sources, at BASE or HEAD
declare -A is_source=()
while IFS=$'\t' read -r tgt src; do
  [ -n "$tgt" ] || continue
  case " ${linked[$tgt]:-} " in *" $src "*) ;; *) linked[$tgt]="${linked[$tgt]:-} $src" ;; esac
  is_source[$src]=1
done < <(links "$base"; links "$head")

# add_linked FILE: map a changed link target to the suite scenarios linking to it.
# Returns 1 when FILE is not a link target, or no suite scenario links to it; 2 for
# a chain of links (a link whose target is a link): the caller maps both to ALL
# unless FILE is itself a scenario script.
add_linked() {
  local src n hit=""
  [ -n "${linked[$1]:-}" ] || return 1
  if [ -n "${is_source[$1]:-}" ]; then out "$1" "ALL (link chain)"; return 2; fi
  for src in ${linked[$1]}; do
    if [ -n "${linked[$src]:-}" ]; then out "$1" "ALL (link chain)"; return 2; fi
    [ "${src%/*}" = "lab/$lab/scenarios" ] || continue
    n=${src##*/}
    n=${n%.sh}
    if has "$suite" "$n"; then names[$n]=1; hit="$hit $n"; fi
  done
  [ -n "$hit" ] || return 1
  out "$1" "linked from$hit"
}
# link_names FILE: add_linked for a scenario script, whose own mapping is done;
# only a chain adds ALL
link_names() {
  local rc=0
  add_linked "$1" || rc=$?
  if [ "$rc" = 2 ]; then all=1; fi
}

out() { [ "$verbose" = 0 ] || echo "  $1: $2" >&2; }

for f in "${changed[@]}"; do
  case "$f" in
    *.md | lab/*/results/*) out "$f" nothing ;;
    */lib.sh | */lib-*.sh) all=1; out "$f" ALL ;;
    "$longlist") out "$f" "nothing (long.txt)" ;;
    "$list")
      new=$(comm -13 <(sort -u <<<"$suite_b") <(sort -u <<<"$suite"))
      while IFS= read -r s; do [ -z "$s" ] || names[$s]=1; done <<<"$new"
      if [ -n "$new" ]; then out "$f" "new in suite.txt: ${new//$'\n'/ }"; else out "$f" "nothing (no names added to suite.txt)"; fi
      ;;
    "lab/$lab/scenarios/"*.sh)
      s=${f##*/}
      s=${s%.sh}
      if [ "${f#"lab/$lab/scenarios/"}" != "${f##*/}" ]; then
        # a script in a subdirectory: only a symlink target matters
        add_linked "$f" || { all=1; out "$f" ALL; }
      elif ! git cat-file -e "$head:$f" 2>/dev/null; then
        if has "$suite" "$s"; then
          all=1
          out "$f" "ALL (deleted but still in suite.txt)"
        elif has "$suite_b" "$s" || has "$long_b" "$s"; then
          out "$f" "nothing (deleted, was in suite.txt or long.txt)"
        else
          all=1
          out "$f" "ALL (deleted, was in neither list)"
        fi
        link_names "$f"
      elif has "$suite" "$s"; then
        names[$s]=1
        out "$f" "$s"
        link_names "$f"
      elif has "$long" "$s"; then
        out "$f" "nothing (long scenario, not in the suite)"
        link_names "$f"
      else
        all=1
        out "$f" "ALL (script is neither in suite.txt nor long.txt)"
      fi
      ;;
    lab/packs/*/tests/* | lab/*/vmalert/tests/*) out "$f" nothing ;;
    lab/*/grafana/dashboards/* | lab/packs/*/dashboards/* | lab/*/mon/*/dashboards/*) out "$f" nothing ;;
    lab/packs/*/*)
      p=${f#lab/packs/}
      p=${p%%/*}
      if uses "$p"; then
        all=1
        out "$f" "ALL (lab uses pack $p)"
      else
        out "$f" "nothing (lab does not use pack $p)"
      fi
      ;;
    *) add_linked "$f" || { all=1; out "$f" ALL; } ;;
  esac
done

if [ "$all" = 1 ]; then
  echo ALL
elif [ "${#names[@]}" -gt 0 ]; then
  printf '%s\n' "${!names[@]}" | sort
fi
