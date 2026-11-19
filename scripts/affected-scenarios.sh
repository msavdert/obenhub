#!/usr/bin/env bash
# Which scenarios of a lab must run again because of the changes between two
# commits: their names, one per line, sorted, or the single line ALL.
#   affected-scenarios.sh [-v] [-f] LAB BASE [HEAD]      (HEAD defaults to HEAD)
# Looks at the files check-evidence.sh watches (scripts/evidence-paths.sh;
# renames count as a delete plus an add) and maps each changed file, the first
# row that applies winning:
#   Markdown, results/, rule unit tests,                         nothing
#     lab/packs/*/upstream-receiver-metrics.txt
#   versions.sh                                                  nothing; with -f (full mode of
#                                                                check-evidence.sh) ALL
#   a .yml/.yaml file that exists at BASE and HEAD with the      nothing
#     same JSON (yq drops comments and formatting), a .sh file
#     with the same lines apart from blank and comment lines
#     (a line-1 #! is kept; a # line inside a heredoc counts as
#     a comment; every #! line is kept), a .toml file with the
#     same JSON (Python 3.11+ tomllib), same file mode
#   alert rules: lab/packs/*/rules.yml (nothing when the lab     control (if in suite.txt) plus the
#     does not use the pack) and YAML under lab/*/vmalert/ or    suite scenarios whose script text
#     lab/*/mon/vmalert/; per alert name the rule objects        (symlinks resolved, BASE or HEAD)
#     without annotations, with their group's other keys,        has the name as a word; ALL when
#     are compared; a name that differs (added, removed,         the name is a word in the lab's
#     expr, for, labels, group) is a changed alert               lib.sh or lib-*.sh or in
#                                                                lab/scenarios/*.sh. Annotation-only
#                                                                changes: nothing
#   anything else in a rule file (recording rules, groups        ALL
#     without alerts, top-level keys), or a rule file yq
#     cannot parse
#   Grafana: lab/*/grafana/, lab/*/mon/grafana/,                 PANELS (lab:<lab>:panels); a pack
#     lab/packs/*/dashboards/ (lab/mon is shared: ALL)           dashboard only when the lab uses
#                                                                the pack, else nothing
#   scenarios/<name>.sh in the lab's suite.txt                   that scenario, and every
#                                                                suite scenario whose symlink
#                                                                (at BASE or HEAD) points at it
#   scenarios/<name>.sh in long.txt, or deleted (it was in       nothing
#     suite.txt or long.txt at BASE), and long.txt itself
#   scenarios/suite.txt                                          names added at HEAD
#   a script under lab/scenarios/<dir>/ that a scenario          the suite scenarios of this lab
#     symlink of any lab (BASE or HEAD) points at                that link to it; nothing when
#                                                                only long.txt scenarios or other
#                                                                labs link to it
#   a file of lab/packs/<p> (not tests or dashboards)            ALL if the lab uses the
#                                                                pack, else nothing
#   every other watched file: lib.sh and lib-*.sh, files         ALL
#     directly in lab/scenarios, a shared script nothing links
#     to, link chains, lab/mon, lab/scripts, inventories,
#     compose files, configs, queries, scripts
# A lab uses pack <p> when a non-Markdown file under lab/<lab> outside results/
# mentions the string packs/<p> at BASE or HEAD (a compose mount of a file or
# of the directory, a script that reads the queries). Only lab/<lab> is
# searched; changes under lab/mon and lab/scripts are ALL themselves.
# Accepted residual risk: a new alert, or a widened one (lower threshold), maps
# only to control and the scenarios that name it; a scenario that now fires it
# incidentally keeps its old pass until the next full suite.
# -f is the full mode of check-evidence.sh --full (the release and update-batch
# gate): version pins then count as changes.
# Output: the scenario names, or ALL, one per line; then a line PANELS when a
# Grafana file changed (not scenario evidence: check-evidence.sh drops it,
# lab-affected.sh turns it into a hint). -v also prints, to stderr, what each
# changed file maps to.
# Exit 2 on bad arguments, 1 on git errors or a missing or wrong yq. Needs git, grep,
# awk, yq (mikefarah v4, pinned in mise.toml).
set -euo pipefail

verbose=0 fullmode=0
while [ "${1:-}" = "-v" ] || [ "${1:-}" = "-f" ]; do
  if [ "$1" = "-v" ]; then verbose=1; else fullmode=1; fi
  shift
done
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: affected-scenarios.sh [-v] [-f] LAB BASE [HEAD]" >&2
  exit 2
fi
lab=$1 base=$2 head=${3:-HEAD}
case "$lab" in *[!a-z0-9]* | "") echo "bad lab name: $lab" >&2; exit 2 ;; esac

yqv=$(yq --version 2>/dev/null || true)
case "$yqv" in
  *mikefarah*" version v4."* | *mikefarah*" version 4."*) ;;
  *) echo "affected-scenarios.sh needs yq by mikefarah, major version 4 (mise.toml pins it, run mise install); found: ${yqv:-none}" >&2; exit 1 ;;
esac
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
  local rev rc
  for rev in "$base" "$head"; do
    rc=0
    git grep -I -q -F -e "packs/$1" "$rev" -- "lab/$lab" ':(exclude,glob)**/*.md' \
      ':(exclude,glob)lab/*/results/**' 2>/dev/null || rc=$?
    [ "$rc" != 0 ] || return 0
    [ "$rc" = 1 ] || { echo "git grep failed (exit $rc) at $rev" >&2; exit 1; }
  done
  return 1
}

# links REV: "target<TAB>source" for every symlink under a lab's scenarios/ (any
# lab) at REV whose target is under this lab's scenarios/ or in a subdirectory
# of lab/scenarios/ (a target elsewhere is not a link target: ALL)
links() {
  local meta path mode blob tgt
  while IFS=$'\t' read -r meta path; do
    # shellcheck disable=SC2086  # split "mode type blob"
    set -- $meta
    mode=$1 blob=$3
    [ "$mode" = 120000 ] || continue
    case "$path" in lab/*/scenarios/*) ;; *) continue ;; esac
    tgt=$(git cat-file -p "$blob")
    tgt=$(realpath -m -s --relative-to=. "${path%/*}/$tgt")
    case "$tgt" in "lab/$lab/scenarios/"* | lab/scenarios/*/*) printf '%s\t%s\n' "$tgt" "$path" ;; esac
  done < <(git ls-tree -r "$1" -- lab)
}
declare -A linked=()   # target -> sources, at BASE or HEAD
declare -A is_source=()
while IFS=$'\t' read -r tgt src; do
  [ -n "$tgt" ] || continue
  case " ${linked[$tgt]:-} " in *" $src "*) ;; *) linked[$tgt]="${linked[$tgt]:-} $src" ;; esac
  is_source[$src]=1
done < <(links "$base"; links "$head")

# add_linked FILE: map a changed link target to the suite scenarios of this lab
# linking to it. Returns 1 when FILE is not a link target, or (unless it is a
# shared script under lab/scenarios/<dir>/, which then maps to nothing) no suite
# scenario of the lab links to it; 2 for a chain of links (a link whose target is
# a link): the caller maps both to ALL unless FILE is itself a scenario script.
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
  if [ -n "$hit" ]; then out "$1" "linked from$hit"; return 0; fi
  case "$1" in
    lab/scenarios/*/*) out "$1" "nothing (linked only from long.txt scenarios or other labs)"; return 0 ;;
  esac
  return 1
}
# link_names FILE: add_linked for a scenario script, whose own mapping is done;
# only a chain adds ALL
link_names() {
  local rc=0
  add_linked "$1" || rc=$?
  if [ "$rc" = 2 ]; then all=1; fi
}

out() { [ "$verbose" = 0 ] || echo "  $1: $2" >&2; }

panels=0
tmpd=$(mktemp -d)
trap 'rm -rf "${tmpd:?}"' EXIT

# mode_of REV PATH: the git file mode, empty when the file is not at REV
mode_of() { git ls-tree "$1" -- "$2" | awk '{print $1}'; }

# yaml_at REV PATH: the file at REV as YAML text; {} when missing or blank
yaml_at() {
  local t
  t=$(show "$1" "$2")
  if [ -n "${t//[[:space:]]/}" ]; then printf '%s\n' "$t"; else echo '{}'; fi
}

toml_json='import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read()), sort_keys=True))'
# comment_only FILE: true when FILE exists at BASE and HEAD with the same mode
# and differs only in comments and formatting (see the header)
comment_only() {
  local f=$1 a b
  [ -n "$(mode_of "$base" "$f")" ] && [ "$(mode_of "$base" "$f")" = "$(mode_of "$head" "$f")" ] || return 1
  case "$f" in
    *.yml | *.yaml)
      a=$(yaml_at "$base" "$f" | yq -o=json -I=0 . 2>/dev/null) || return 1
      b=$(yaml_at "$head" "$f" | yq -o=json -I=0 . 2>/dev/null) || return 1
      [ -n "$a" ] && [ -n "$b" ] || return 1  # blank input became {}: empty output means yq failed
      [ "$a" = "$b" ]
      ;;
    *.toml)
      # tomllib: Python 3.11 or later (mise.toml pins python)
      a=$(show "$base" "$f" | python3 -c "$toml_json" 2>/dev/null) || return 1
      b=$(show "$head" "$f" | python3 -c "$toml_json" 2>/dev/null) || return 1
      [ "$a" = "$b" ]
      ;;
    *.sh)
      a=$(show "$base" "$f" | awk '/^#!/ {print; next} /^[[:space:]]*(#|$)/ {next} {print}')
      b=$(show "$head" "$f" | awk '/^#!/ {print; next} /^[[:space:]]*(#|$)/ {next} {print}')
      [ "$a" = "$b" ]
      ;;
    *) return 1 ;;
  esac
}

# alert_lines REV PATH: "name<TAB>canonical rule JSON" per alert rule, sorted;
# annotations removed, the group's other keys attached
alert_lines() {
  # shellcheck disable=SC2016  # $g is a yq variable
  yaml_at "$1" "$2" | yq -r '[.groups[]? | . as $g | .rules[]? | select(has("alert")) | del(.annotations) | sort_keys(..) | {"a": .alert, "r": (. + {"_g": ($g | del(.rules))})}] | .[] | .a + "\t" + (.r | to_json(0))' | LC_ALL=C sort
}
# rest_json REV PATH: the document without its alert rules (and without the
# groups that only held alerts)
rest_json() {
  yaml_at "$1" "$2" | yq -o=json -I=0 '.groups = ((.groups // []) | map(select(([.rules[]? | select(has("alert"))] | length) == 0 or ([.rules[]? | select(has("alert") | not)] | length) > 0))) | del(.groups[].rules[] | select(has("alert")))'
}

# scenario_text REV NAME: the script of suite scenario NAME at REV, symlinks resolved
scenario_text() {
  local p=lab/$lab/scenarios/$2.sh m t
  for _ in 1 2 3 4 5 6 7 8; do
    m=$(mode_of "$1" "$p")
    [ -n "$m" ] || return 0
    if [ "$m" != 120000 ]; then show "$1" "$p"; return 0; fi
    t=$(show "$1" "$p")
    p=$(realpath -m -s --relative-to=. "${p%/*}/$t")
  done
}
texts_ready=0
prepare_texts() {
  [ "$texts_ready" = 0 ] || return 0
  texts_ready=1
  local n rev p
  mkdir -p "$tmpd/scen"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    { scenario_text "$base" "$n"; scenario_text "$head" "$n"; } >"$tmpd/scen/$n"
  done <<<"$suite"
  : >"$tmpd/lib"
  for rev in "$base" "$head"; do
    while IFS= read -r p; do
      case "${p##*/}" in
        lib.sh | lib-*.sh) [ "${p%/*}" = "lab/$lab/scenarios" ] || [ "${p%/*}" = lab/scenarios ] || continue ;;
        *.sh) [ "${p%/*}" = lab/scenarios ] || continue ;;
        *) continue ;;
      esac
      show "$rev" "$p" >>"$tmpd/lib"
    done < <(git ls-tree --name-only "$rev" "lab/$lab/scenarios/" lab/scenarios/)
  done
}

# alert_file FILE: map a changed alert rule file; sets all/names
alert_file() {
  local f=$1 la lb ra rb changed n hit s
  if ! { la=$(alert_lines "$base" "$f" 2>/dev/null) && lb=$(alert_lines "$head" "$f" 2>/dev/null) \
    && ra=$(rest_json "$base" "$f" 2>/dev/null) && rb=$(rest_json "$head" "$f" 2>/dev/null) \
    && [ -n "$ra" ] && [ -n "$rb" ]; }; then
    all=1; out "$f" "ALL (yq cannot parse it)"; return
  fi
  if [ "$ra" != "$rb" ]; then all=1; out "$f" "ALL (non-alert rule change)"; return; fi
  changed=$(comm -3 <(printf '%s\n' "$la" | grep -v '^$' || true) <(printf '%s\n' "$lb" | grep -v '^$' || true) | sed 's/^\t//' | cut -f1 | sort -u)
  if [ -z "$changed" ]; then out "$f" "nothing (no alert changed apart from annotations)"; return; fi
  prepare_texts
  while IFS= read -r n; do
    hit=""
    if grep -qwF -- "$n" "$tmpd/lib"; then all=1; out "$f" "alert $n -> ALL (named in a scenario library)"; continue; fi
    if has "$suite" control; then names[control]=1; hit=control; fi
    while IFS= read -r s; do
      [ -n "$s" ] && [ "$s" != control ] || continue
      if grep -qwF -- "$n" "$tmpd/scen/$s"; then names[$s]=1; hit="$hit $s"; fi
    done <<<"$suite"
    out "$f" "alert $n -> ${hit:-no scenario}"
  done <<<"$changed"
}

for f in "${changed[@]}"; do
  case "$f" in
    *.md | lab/*/results/*) out "$f" nothing ;;
    */versions.sh)
      if [ "$fullmode" = 1 ]; then all=1; out "$f" "ALL (version pins: full mode)"; else out "$f" "nothing (version bumps ride the update batch)"; fi
      ;;
    lab/packs/*/upstream-receiver-metrics.txt) out "$f" "nothing (reference list)" ;;
    lab/packs/*/tests/* | lab/*/vmalert/tests/*) out "$f" nothing ;;
    *) if comment_only "$f"; then out "$f" "nothing (comments or formatting only)"; continue; fi ;;&
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
    lab/mon/*) all=1; out "$f" ALL ;;
    lab/packs/*/dashboards/*)
      p=${f#lab/packs/}
      p=${p%%/*}
      if uses "$p"; then panels=1; out "$f" "PANELS (lab uses pack $p)"; else out "$f" "nothing (lab does not use pack $p)"; fi
      ;;
    lab/*/grafana/* | lab/*/mon/*/dashboards/*) panels=1; out "$f" PANELS ;;
    lab/packs/*/rules.yml)
      p=${f#lab/packs/}
      p=${p%%/*}
      if uses "$p"; then alert_file "$f"; else out "$f" "nothing (lab does not use pack $p)"; fi
      ;;
    lab/*/vmalert/*.yml | lab/*/vmalert/*.yaml) alert_file "$f" ;;
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
if [ "$panels" = 1 ]; then echo PANELS; fi
