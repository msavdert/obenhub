#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Verify that commit subjects in a range follow Conventional Commits.
# Merge commits are skipped (history is squash-merged). git's default revert
# subject (Revert "<subject>") is accepted. Scopes may use upper-case letters,
# matching amannn/action-semantic-pull-request.
# Usage: check-commits.sh <base> <head>
# An empty or all-zero base checks every commit reachable from head.
set -euo pipefail

base="${1:-}"
head="${2:-HEAD}"
zero="0000000000000000000000000000000000000000"

if [[ -z "$base" || "$base" == "$zero" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  range="$head"
else
  range="${base}..${head}"
fi

pattern='^(feat|fix|docs|chore|ci|build|refactor|perf|test|revert)(\([A-Za-z0-9._/-]+\))?!?: .+|^Revert ".+"$'
log=$(git log --no-merges --format='%H%x09%s' "$range")
status=0
count=0
while IFS=$'\t' read -r sha subject; do
  [[ -n "$sha" ]] || continue
  count=$((count + 1))
  if ! [[ "$subject" =~ $pattern ]]; then
    echo "not a Conventional Commit: ${sha:0:12} ${subject}" >&2
    status=1
  fi
done <<< "$log"

echo "checked ${count} commit(s) in ${range}"
exit "$status"
