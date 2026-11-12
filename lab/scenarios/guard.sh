#!/usr/bin/env bash
# Run guards shared by lab/scenarios/lib-core.sh and lab/scenarios/run-suite.sh:
# which tree state counts as dirty, and the host-wide lock that keeps two runs
# (suites or single scenarios, in any lab) from overlapping. Source it; do not
# run it. Tested by lab/scenarios/test-guard.sh.
#
# Dirty means any change outside lab/<lab>/results/ (exactly one directory
# level between lab/ and results/): the harness itself appends to the tracked
# runs.jsonl files, so those must not count.
#
# The lock file holds "<SUITE_ID> <pid of run-suite.sh>" while a suite runs and
# "smoke <pid>" while a single scenario runs. A scenario trusts an inherited
# SUITE_ID only when the lock is held, the file names that id, and that pid is
# alive and an ancestor of the scenario. run-suite.sh starts every scenario with
# fd 9 (the lock) closed, so background children of a scenario cannot keep the
# suite lock alive. A single scenario that takes the lock itself cannot do
# that: processes it leaves running in the background inherit the lock until
# they exit.

GUARD_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# one fixed path per user for all labs: /run/user/<uid> (private to the user;
# /tmp is world-writable, a planted symlink would be followed) when that
# directory exists and is writable, else /tmp. XDG_RUNTIME_DIR is deliberately
# not read: cron, sudo -u, env -i and system units run without it, and two runs
# would then lock different files. Residual: if /run/user/<uid> appears or
# disappears between two runs (session ends, linger off) they disagree; linger
# is on on the box. The override exists for test-guard.sh only.
if [ -z "${SUITE_LOCK_FILE:-}" ]; then
  # a failing id must not abort a caller running under set -e: fall back to /tmp
  _guard_uid=$(id -u 2>/dev/null) || _guard_uid=
  _guard_rt="/run/user/$_guard_uid"
  if [ -n "$_guard_uid" ] && [ -d "$_guard_rt" ] && [ -w "$_guard_rt" ]; then
    SUITE_LOCK_FILE="$_guard_rt/obenhub-lab-suite.lock"
  else
    SUITE_LOCK_FILE=/tmp/obenhub-lab-suite.lock
  fi
  unset _guard_uid _guard_rt
fi

# dirty_paths: porcelain lines of changed or untracked paths outside
# lab/<lab>/results/. Fails (status 2, message on stderr) when git fails, so a
# broken check never reads as clean.
dirty_paths() {
  local out
  out=$(git -C "$GUARD_TOP" status --porcelain -- . ':(exclude,glob)lab/*/results/**') \
    || { echo "git status failed in $GUARD_TOP" >&2; return 2; }
  printf '%s' "$out"
}
# git_dirty: true when dirty or when that cannot be told
git_dirty() {
  local d
  d=$(dirty_paths 2>/dev/null) || { echo true; return; }
  [ -n "$d" ] && echo true || echo false
}
git_sha() { git -C "$GUARD_TOP" rev-parse --short HEAD 2>/dev/null || echo unknown; }

# lock_path_safe: fails (message on stderr) when the lock path is a symlink;
# opening it would write through the link
lock_path_safe() {
  [ ! -L "$SUITE_LOCK_FILE" ] || { echo "refusing to use $SUITE_LOCK_FILE: it is a symlink" >&2; return 1; }
}
# lock_taken: succeeds when some process holds the suite lock (and, failing
# closed, when the lock path is unusable)
lock_taken() {
  lock_path_safe || return 0
  ( exec 8>>"$SUITE_LOCK_FILE" || { echo "cannot open lock file $SUITE_LOCK_FILE; treating the lock as taken" >&2; exit 0; }
    ! flock -n 8 )
}
# lock_acquire LABEL: take the lock on fd 9 for the rest of this process and
# record "LABEL pid" in the lock file; fails when it is held
lock_acquire() {
  lock_path_safe || return 1
  exec 9>>"$SUITE_LOCK_FILE" && flock -n 9 || return 1
  printf '%s %s\n' "$1" "$$" >"$SUITE_LOCK_FILE"
}
# ppid_of PID
ppid_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $2}'; }
# suite_trusted ID: the lock names suite ID, its run-suite.sh process is alive
# and an ancestor of this process
suite_trusted() {
  local id pid p
  lock_path_safe 2>/dev/null || return 1
  read -r id pid <"$SUITE_LOCK_FILE" 2>/dev/null || return 1
  [ -n "$id" ] && [ "$id" = "$1" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$pid" ] && return 0
    p=$(ppid_of "$p")
  done
  return 1
}
# scenario_lock: for a scenario about to run. Keeps SUITE_ID when a suite that
# is an ancestor holds the lock; otherwise clears it and takes the lock itself
# (a smoke run). Returns 3 when the lock is held by anything else.
scenario_lock() {
  if lock_taken; then
    [ -n "${SUITE_ID:-}" ] && suite_trusted "$SUITE_ID" && return 0
    return 3
  fi
  SUITE_ID=""
  # shellcheck disable=SC2034  # read by lib-core.sh write_result
  SUITE_SIZE=""
  lock_acquire smoke || return 3
}
