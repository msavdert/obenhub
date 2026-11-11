#!/usr/bin/env bash
# Run shellcheck on every tracked shell script: files named *.sh, and extension-less
# files whose first line is a bash or sh shebang. Found with git ls-files, so
# a new script is covered without editing a glob list.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

files=()
while IFS= read -r -d '' f; do
  case "${f##*/}" in
    *.sh) files+=("$f") ;;
    *.*) ;;
    *) if head -n1 "$f" 2>/dev/null | grep -aqE '^#!(/usr)?/bin/(env +)?(bash|sh)( |$)'; then files+=("$f"); fi ;;
  esac
done < <(git ls-files -z)

echo "shellcheck: ${#files[@]} scripts"
shellcheck "${files[@]}"
