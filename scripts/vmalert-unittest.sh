#!/usr/bin/env bash
# Run vmalert-tool unittest on every *.yml of the given test directories (paths
# under lab/ or packs/), so a new test file is never skipped. The image is pinned in
# packs/versions.sh. A directory without a *.yml, or outside lab/ and packs/, is an error.
# Usage: scripts/vmalert-unittest.sh packs/patroni/tests [packs/etcd/tests ...]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=packs/versions.sh
. packs/versions.sh

[ "$#" -gt 0 ] || { echo "usage: $0 DIR..." >&2; exit 2; }
files=""
for d in "$@"; do
  d=${d%/}
  case "$d" in lab/* | packs/*) ;; *) echo "$d: not under lab/ or packs/" >&2; exit 2 ;; esac
  found=0
  for f in "$d"/*.yml; do
    [ -e "$f" ] || continue
    files="$files/repo/$f,"
    found=1
  done
  [ "$found" = 1 ] || { echo "$d: no *.yml test files" >&2; exit 2; }
done
exec docker run --rm -v "$PWD:/repo:ro" "$VMALERT_TOOL_IMAGE" unittest --files="${files%,}"
