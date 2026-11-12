#!/bin/sh
# archive_command of the slice 1 nodes: archive-wal.sh %p %f
# Rules from the PostgreSQL 18 docs, 25.3.1 Setting Up WAL Archiving
# (https://www.postgresql.org/docs/18/continuous-archiving.html):
# - never overwrite an archived file;
# - PostgreSQL may archive a file again after a crash that lost the record of
#   its success, so an existing file with identical content (and persisted to
#   storage) is a success, an existing file with different content a failure;
# - exit 0 only when the file is archived.
# A new file is copied under a temporary name, flushed and renamed, so a
# crash never leaves a partial file under the real name.
set -eu
src=$1
dst=/archive/$2
if [ -f "$dst" ]; then
  cmp -s "$src" "$dst" || exit 1
  sync "$dst"
  exit 0
fi
tmp=/archive/.$2.tmp
if cp "$src" "$tmp" && sync "$tmp" && mv "$tmp" "$dst" && sync /archive; then
  exit 0
fi
rm -f "$tmp"
exit 1
