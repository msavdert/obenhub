#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC2329
# Test of lab/scenarios/guard.sh and run-suite.sh in a throwaway git repository:
# the dirty pathspec and the suite lock. No docker, no lab; takes a few seconds.
# Run it with `mise run lab:guard-test` (part of `mise run check`).
set -u

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work=$(mktemp -d)
FAILED=0
cleanup() {
  [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null
  [ -n "${BGPID:-}" ] && kill "$BGPID" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=1; }
check() { # description command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
check_not() { # description command...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}

repo=$work/repo
export SUITE_LOCK_FILE=$work/lock
mkdir -p "$repo/lab/scenarios" "$repo/lab/x/results" "$repo/lab/t/scenarios" "$repo/lab/a/b/results"
cp "$src/guard.sh" "$src/run-suite.sh" "$repo/lab/scenarios/"
echo '{}' >"$repo/lab/x/results/runs.jsonl"
echo '{}' >"$repo/lab/a/b/results/z"
echo a >"$repo/lab/tracked"
# fake lab "t": scenarios report what scenario_lock decided
cat >"$repo/lab/t/scenarios/who.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/../../scenarios/guard.sh"
scenario_lock; rc=$?
echo "rc=$rc suite=${SUITE_ID:-}" >"$WHO_OUT"
EOF
cat >"$repo/lab/t/scenarios/hold.sh" <<'EOF'
#!/usr/bin/env bash
until [ -e "$HOLD_RELEASE" ]; do sleep 0.1; done
EOF
cat >"$repo/lab/t/scenarios/bg.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
echo $! >"$BG_PID"
EOF
chmod +x "$repo"/lab/t/scenarios/*.sh "$repo/lab/scenarios/run-suite.sh"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init

# in_repo CMD: run CMD in a fresh bash with guard.sh sourced
in_repo() { bash -c '. "$1/lab/scenarios/guard.sh"; shift; eval "$*"' _ "$repo" "$@"; }

echo "--- dirty pathspec"
check "clean tree is clean" in_repo '[ -z "$(dirty_paths)" ] && [ "$(git_dirty)" = false ]'
echo '{"a":1}' >>"$repo/lab/x/results/runs.jsonl"
echo '{}' >"$repo/lab/x/results/new.jsonl"
check "modified and new files in lab/<lab>/results/ are ignored" in_repo '[ -z "$(dirty_paths)" ] && [ "$(git_dirty)" = false ]'
echo x >>"$repo/lab/a/b/results/z"
check "results/ under a deeper directory is dirty" in_repo '[ "$(git_dirty)" = true ]'
git -C "$repo" checkout -q -- lab/a/b/results/z
echo x >"$repo/lab/a/b/results/new"
check "untracked file in a deeper results/ is dirty" in_repo '[ "$(git_dirty)" = true ]'
rm "$repo/lab/a/b/results/new"
echo x >>"$repo/lab/tracked"
check "modified tracked file is dirty" in_repo '[ "$(git_dirty)" = true ] && dirty_paths | grep -q tracked'
git -C "$repo" checkout -q -- lab/tracked
echo x >"$repo/lab/untracked"
check "untracked file is dirty" in_repo '[ "$(git_dirty)" = true ]'
rm "$repo/lab/untracked"
mkdir -p "$work/norepo/lab/scenarios"
cp "$src/guard.sh" "$work/norepo/lab/scenarios/"
check_not "a failing git status fails dirty_paths" bash -c '. "$1/lab/scenarios/guard.sh"; dirty_paths' _ "$work/norepo"
check "a failing git status reads as dirty in git_dirty" bash -c '. "$1/lab/scenarios/guard.sh"; [ "$(git_dirty)" = true ]' _ "$work/norepo"

echo "--- lock"
# a smoke run holds the lock; a second taker is refused
bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock && exec sleep 30' _ "$repo" &
HOLDER=$!
until [ -s "$SUITE_LOCK_FILE" ]; do sleep 0.1; done
check "lock file names the smoke holder" grep -q '^smoke ' "$SUITE_LOCK_FILE"
check_not "second taker is refused" in_repo 'scenario_lock'
check_not "second run-suite is refused" "$repo/lab/scenarios/run-suite.sh" t who
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=
check "lock is free after the holder exits" in_repo '! lock_taken'

# a suite runs a scenario that asks scenario_lock
export WHO_OUT=$work/who
"$repo/lab/scenarios/run-suite.sh" t who >"$work/suite.out" 2>&1
check "scenario in a suite keeps the SUITE_ID (matching content, ancestor pid)" grep -Eq '^rc=0 suite=t-[0-9]{8}T[0-9]{6}Z-' "$WHO_OUT"
check "lock is free after the suite" in_repo '! lock_taken'
SUITE_ID=stale in_repo 'scenario_lock; [ -z "$SUITE_ID" ]' && ok "stale SUITE_ID with a free lock becomes a smoke run (suite cleared)" || bad "stale SUITE_ID with a free lock becomes a smoke run"

# a suite holds the lock while a scenario waits; probes from outside it
export HOLD_RELEASE=$work/release
"$repo/lab/scenarios/run-suite.sh" t hold >"$work/suite2.out" 2>&1 &
SUITE=$!
until grep -q '^t-' "$SUITE_LOCK_FILE" 2>/dev/null; do sleep 0.1; done
id=$(cut -d' ' -f1 "$SUITE_LOCK_FILE")
check_not "stale SUITE_ID is refused while a suite holds the lock" env SUITE_ID=t-stale bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo"
check_not "the real SUITE_ID is refused from a process that is not a descendant of the suite" env SUITE_ID="$id" bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo"
check_not "no SUITE_ID is refused while a suite holds the lock" in_repo 'scenario_lock'
touch "$HOLD_RELEASE"
wait "$SUITE"
check "suite finished cleanly" test $? -eq 0
check "lock is free after the second suite" in_repo '! lock_taken'

# fd 9 must not reach background children of a scenario
export BG_PID=$work/bgpid
"$repo/lab/scenarios/run-suite.sh" t bg >"$work/suite3.out" 2>&1
BGPID=$(cat "$BG_PID")
check "background child of a scenario is still running" kill -0 "$BGPID"
check "background child of a scenario does not keep the suite lock" in_repo '! lock_taken'

# a symlink at the lock path is refused and its target is not written
echo keep >"$work/target"
ln -s "$work/target" "$work/linklock"
check_not "lock_acquire refuses a symlinked lock path" env SUITE_LOCK_FILE="$work/linklock" bash -c '. "$1/lab/scenarios/guard.sh"; lock_acquire smoke' _ "$repo"
check_not "scenario_lock refuses a symlinked lock path" env SUITE_LOCK_FILE="$work/linklock" bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo"
check "a symlinked lock path reads as taken" env SUITE_LOCK_FILE="$work/linklock" bash -c '. "$1/lab/scenarios/guard.sh"; lock_taken' _ "$repo"
check "the symlink target is untouched" test "$(cat "$work/target")" = keep

# a symlinked lock path whose target names the suite id and a live ancestor pid must not be trusted
echo "t-fake $$" >"$work/target"
check_not "suite_trusted refuses a symlinked lock path" env SUITE_LOCK_FILE="$work/linklock" bash -c '. "$1/lab/scenarios/guard.sh"; suite_trusted t-fake' _ "$repo"
check_not "scenario_lock does not return 0 through a symlinked lock path" env SUITE_ID=t-fake SUITE_LOCK_FILE="$work/linklock" bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo"

# an unusable (not symlink) lock path fails closed
nolock=$work/nodir/lock
check "lock_taken reads an unopenable lock file as taken" env SUITE_LOCK_FILE="$nolock" bash -c '. "$1/lab/scenarios/guard.sh"; lock_taken' _ "$repo"
check_not "scenario_lock refuses an unopenable lock file" env SUITE_LOCK_FILE="$nolock" bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo"
check_not "lock_acquire fails on an unopenable lock file" env SUITE_LOCK_FILE="$nolock" bash -c '. "$1/lab/scenarios/guard.sh"; lock_acquire smoke' _ "$repo"
env SUITE_LOCK_FILE="$nolock" bash -c '. "$1/lab/scenarios/guard.sh"; scenario_lock' _ "$repo" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "scenario_lock returns 3 on an unopenable lock file" || bad "scenario_lock returns 3 on an unopenable lock file (got $rc)"

# the default path must not depend on XDG_RUNTIME_DIR
default_path() { env -u SUITE_LOCK_FILE "$@" bash -c '. "$1/lab/scenarios/guard.sh"; echo "$SUITE_LOCK_FILE"' _ "$repo"; }
p1=$(default_path -u XDG_RUNTIME_DIR)
p2=$(default_path XDG_RUNTIME_DIR=/nonexistent-bogus)
[ -n "$p1" ] && [ "$p1" = "$p2" ] && ok "default lock path ignores XDG_RUNTIME_DIR ($p1)" || bad "default lock path differs: '$p1' vs '$p2'"

[ "$FAILED" = 0 ] && echo "guard tests passed" || echo "guard tests FAILED"
exit "$FAILED"
