#!/usr/bin/env bash
# Run vmalert-tool unittest on every *.yml of the given test directories (paths
# under lab/), so a new test file is never skipped. The image is pinned in
# lab/packs/versions.sh. A directory without a *.yml, or outside lab/, is an error.
# Usage: scripts/vmalert-unittest.sh lab/packs/patroni/tests [lab/packs/etcd/tests ...]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lab/packs/versions.sh
. lab/packs/versions.sh

[ "$#" -gt 0 ] || { echo "usage: $0 DIR..." >&2; exit 2; }
files=""
for d in "$@"; do
  d=${d%/}
  case "$d" in lab/*) ;; *) echo "$d: not under lab/" >&2; exit 2 ;; esac
  found=0
  for f in "$d"/*.yml; do
    [ -e "$f" ] || continue
    files="$files/$f,"
    found=1
  done
  [ "$found" = 1 ] || { echo "$d: no *.yml test files" >&2; exit 2; }
done
exec docker run --rm -v "$PWD/lab:/lab:ro" "$VMALERT_TOOL_IMAGE" unittest --files="${files%,}"
