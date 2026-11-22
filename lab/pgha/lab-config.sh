#!/usr/bin/env bash
# Source the untracked, per-site address file of a lab (lab/pgha/nodes.sh,
# lab/oracle/gateway.sh, lab/oracle/pair.sh) or stop with one line naming the
# tracked example to copy. Sourced, never run:
#   . "$dir/lab-config.sh"; lab_config "$dir/nodes.sh"
# The variables the file sets stay in the caller's shell.

lab_config() {
  local f=$1 root rel
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  rel=${f#"$root"/}
  if [ ! -f "$f" ]; then
    echo "lab-config: $rel is missing; copy ${rel%.sh}.example.sh to $rel and edit it" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$f"
}
