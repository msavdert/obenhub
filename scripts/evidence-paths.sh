#!/usr/bin/env bash
# Sourced by check-evidence.sh and affected-scenarios.sh: the one definition of
# which paths a lab's evidence depends on.
#   evidence_extra_paths LAB   paths the lab mounts or sources from
#                              other labs (read from lab/pgha/mon/compose.yaml,
#                              lab/k8s/mon/compose.yaml and the `. versions.sh`
#                              of lab/oracle/scripts/collector.sh; keep in step).
#                              mise.k8s.toml pins the k8s tools; mise.toml (task
#                              definitions) is deliberately not watched
#   evidence_pathspec LAB      sets EVIDENCE_SPEC, a git pathspec: the lab,
#                              lab/packs, lab/scenarios, lab/mon, lab/scripts and
#                              the extra paths, without Markdown and results/

evidence_extra_paths() {
  case "$1" in
    pgha) echo lab/stage3/grafana/dashboards lab/slice1/grafana/dashboards ;;
    k8s) echo lab/slice1/grafana/dashboards mise.k8s.toml ;;
    oracle) echo lab/pgha/versions.sh ;;
  esac
}

evidence_pathspec() {
  local extra
  read -r -a extra <<<"$(evidence_extra_paths "$1")"
  # shellcheck disable=SC2034  # read by the sourcing script
  EVIDENCE_SPEC=("lab/$1" lab/packs lab/scenarios lab/mon lab/scripts "${extra[@]}"
    ':(exclude,glob)lab/*/results/**' ':(exclude,glob)**/*.md')
}
