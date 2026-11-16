#!/usr/bin/env bash
# Test of the ORA-38761 parser and the broker log marker logic of
# lab/oracle/scripts/restore-roles.sh (no VM, no database; ora_sh and
# rr_drc_log are replaced by stubs). Run by mise run lab:oracle:restore-roles-test
# (part of mise run check).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/oracle/scripts/restore-roles.sh
. "$here/restore-roles.sh"
fail=0
ok() { echo "[lab:oracle:restore-roles-test] ok   $1"; }
bad() { echo "[lab:oracle:restore-roles-test] FAIL $1: got '$2', wanted '$3'" >&2; fail=1; }
expect() { # expect <description> <wanted> <got>
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi
}
parse() { rr_parse_38761 <<<"$1"; }

expect "lowest sequence of the newest line's thread" "41 1" "$(parse "  ORA-38761: redo log sequence 43 in thread 1, incarnation 10 could
  ORA-38762: redo logs needed for SCN 9865328 to SCN 9869481
  ORA-38761: redo log sequence 41 in thread 1, incarnation 10 could
  ORA-38761: redo log sequence 42 in thread 1, incarnation 10 could")"
expect "numeric, not text, minimum" "9 1" "$(parse "ORA-38761: redo log sequence 100 in thread 1, x
ORA-38761: redo log sequence 9 in thread 1, x")"
expect "other threads do not count" "7 2" "$(parse "ORA-38761: redo log sequence 3 in thread 1, x
ORA-38761: redo log sequence 9 in thread 2, x
ORA-38761: redo log sequence 7 in thread 2, x")"
expect "no line" "" "$(parse "ORA-38762: redo logs needed for SCN 1 to SCN 2")"

# marker: ora_sh serves a fake broker log; only the lines after the marker are read
LOG=$(mktemp)
trap 'rm -f "${LOG:?}"' EXIT
PRIMARY_SID=CDB19
rr_drc_log() { echo "$LOG"; }
ora_sh() { shift; bash -c "$1"; }
printf '%s\n' "old" "ORA-38761: redo log sequence 5 in thread 1, x" >"$LOG"
rr_mark
expect "marker is the line count" "2" "$RR_MARK"
printf '%s\n' "ORA-38761: redo log sequence 99 in thread 1, x" "ORA-38761: redo log sequence 90 in thread 1, x" >>"$LOG"
new=$(ora_sh "$PRIMARY_SID" "tail -n +$((RR_MARK + 1)) $LOG | grep 'ORA-38761'" | rr_parse_38761) || true
expect "lines before the marker are ignored, minimum of the new ones" "90 1" "$new"
rr_mark
new=$(ora_sh "$PRIMARY_SID" "tail -n +$((RR_MARK + 1)) $LOG | grep 'ORA-38761'" | rr_parse_38761) || true
expect "no new line after a fresh marker: nothing" "" "$new"
# without a new line the restore falls back before RMAN is asked
RR_LAST_KEY=""
if rr_restore_archivelogs 2>/dev/null; then bad "restore falls back without a new line" "restored" "fallback"; else ok "restore falls back without a new line"; fi
expect "no attempt counted" "0/0" "$RR_ARCH_RESTORE_ROUNDS/$RR_ARCH_RESTORE_FAILED"
# the same sequence and thread as the last attempt is not tried again
printf '%s\n' "ORA-38761: redo log sequence 90 in thread 1, x" >>"$LOG"
RR_LAST_KEY="90:1"
MSG=$(mktemp)
trap 'rm -f "${LOG:?}" "${MSG:?}"' EXIT
rr_log() { echo "$*" >>"$MSG"; }
failed_before=$RR_ARCH_RESTORE_FAILED
if rr_restore_archivelogs; then bad "repeat of the last sequence is refused" "restored" "fallback"; else ok "repeat of the last sequence is refused"; fi
if grep 'tried already' "$MSG" >/dev/null; then ok "refused before RMAN (logged as tried already)"; else bad "refused before RMAN" "$(cat "$MSG")" "tried already"; fi
expect "the refusal is not a failed RMAN attempt" "$failed_before" "$RR_ARCH_RESTORE_FAILED"
exit "$fail"
