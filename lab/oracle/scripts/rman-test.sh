#!/usr/bin/env bash
# Stub tests for lab/oracle/files/rman-backup.sh and lab/oracle/scripts/rman.sh:
# sqlplus, rman, crontab and ssh are replaced by shell stubs in a temporary
# directory, so no VM and no database is touched. Run by mise run
# lab:oracle:rman-test (part of mise run check).
# shellcheck disable=SC2329  # has and hasnt are called through check
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup="$here/../files/rman-backup.sh"
rmansh="$here/rman.sh"
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fail=0
ok() { echo "[lab:oracle:rman-test] ok   $1"; }
bad() { echo "[lab:oracle:rman-test] FAIL $1" >&2; [ -s "${T:-}/out" ] && sed "s/^/    | /" "$T/out" >&2; fail=1; }
check() { # check <description> <command...>
  local d=$1; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
has() { grep -q -- "$1" "$2"; }
hasnt() { ! grep -q -- "$1" "$2"; }

# --- stubs for rman-backup.sh -------------------------------------------------
mkdir -p "$T/home/bin" "$T/data" "$T/state" "$T/logs"
echo "T1:$T/home:N" >"$T/oratab"
cat >"$T/home/bin/sqlplus" <<'EOF'
#!/bin/bash
sql=$(cat)
echo "$sql" >>"$STUB/sql.log"
case $sql in
  *"alter "*) ;;
  *database_role*) cat "$STUB/state/role" ;;
  *dg_broker_start*) cat "$STUB/state/broker" ;;
  *block_change_tracking*) cat "$STUB/state/bct" ;;
  *"from v\$datafile"*) echo "$STUB/data/system01.dbf" ;;
  *"alter "*) ;;
  *record_keep_time*) cat "$STUB/state/keep" ;;
esac
exit 0
EOF
cat >"$T/home/bin/rman" <<'EOF'
#!/bin/bash
cmds=$(cat)
echo "$cmds" >>"$STUB/rman.log"
case $cmds in
  "show all;") cat "$STUB/state/show" ;;
  CONFIGURE*) echo "new RMAN configuration parameters are successfully stored" ;;
esac
exit 0
EOF
chmod +x "$T/home/bin/sqlplus" "$T/home/bin/rman"
export STUB="$T"
converged='CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON; # default
CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET PARALLELISM 1;
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;'
fresh='CONFIGURE RETENTION POLICY TO REDUNDANCY 1; # default
CONFIGURE CONTROLFILE AUTOBACKUP ON; # default
CONFIGURE DEVICE TYPE DISK PARALLELISM 1 BACKUP TYPE TO BACKUPSET; # default
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;'
reset() { # reset <role> <broker> <bct> <keep> <show>
  rm -rf "$T/logs" "$T/sql.log" "$T/rman.log"; mkdir -p "$T/logs"
  printf '%s\n' "$1" >"$T/state/role"; printf '%s\n' "$2" >"$T/state/broker"
  printf '%s\n' "$3" >"$T/state/bct"; printf '%s\n' "$4" >"$T/state/keep"
  printf '%s\n' "$5" >"$T/state/show"
}
run() { ORATAB="$T/oratab" RMAN_LOG_DIR="$T/logs" "$backup" T1 "$@"; }

reset 'PHYSICAL STANDBY' true DISABLED 7 "$fresh"
rc=0; run arch >"$T/out" 2>&1 || rc=$?
check "standby backup run exits 0" test "$rc" = 0
check "standby backup run logs one skipped line" has 'skipped: role is PHYSICAL STANDBY' "$T/logs/T1-skipped.log"
check "standby backup run starts no rman" test ! -e "$T/rman.log"

rc=0; run configure >"$T/out" 2>&1 || rc=$?
check "standby configure exits 0" test "$rc" = 0
check "standby configure keeps the deletion policy (already set)" has 'unchanged: CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;' "$T/out"
check "standby configure does not touch retention or BCT" hasnt 'RETENTION\|block change' "$T/out"
check "standby configure sets record keep time 21" has 'control_file_record_keep_time 7 -> 21' "$T/out"
check "standby configure runs no backup" hasnt 'backup' "$T/rman.log"

reset PRIMARY true DISABLED 21 "$fresh"
rc=0; run level1 >"$T/out" 2>&1 || rc=$?
check "primary of a broker configuration exits 0" test "$rc" = 0
for s in 'RECOVERY WINDOW OF 7 DAYS' 'COMPRESSED BACKUPSET;' 'BACKED UP 1 TIMES TO DISK;'; do
  check "primary converges: $s" has "change: .* -> CONFIGURE .*$s" "$T/logs/T1-configure.log"
done
check "primary enables BCT beside datafile 1" has "ENABLED in $T/data/bct.chg" "$T/logs/T1-configure.log"
check "primary does not touch record keep time before a backup" hasnt 'keep_time' "$T/logs/T1-configure.log"
check "settings come before the backup" test "$(grep -n 'CONFIGURE' "$T/rman.log" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'backup incremental level 1' "$T/rman.log" | cut -d: -f1)"
reset PRIMARY true ENABLED 21 "$converged"
run level1 >"$T/out" 2>&1
check "second run changes nothing" hasnt 'change:' "$T/logs/T1-configure.log"
check "second run still backs up" has 'backup incremental level 1' "$T/rman.log"

reset PRIMARY false DISABLED 7 "$fresh"
run arch >"$T/out" 2>&1
check "a database without broker (CDB26) gets no setting" hasnt 'CONFIGURE' "$T/rman.log"
check "a database without broker still backs up" has 'backup archivelog all' "$T/rman.log"

reset 'ORA-01034: ORACLE not available' true DISABLED 7 "$fresh"
rc=0; run arch >"$T/out" 2>&1 || rc=$?
check "an unreadable role fails" test "$rc" = 1

reset PRIMARY true ENABLED 21 "$converged"
(exec 9>"$T/logs/.T1.lock"; flock -n 9; sleep 3) &
sleep 1
rc=0; run arch >"$T/out" 2>&1 || rc=$?
wait
check "a held lock skips with one line" has 'skipped: another run holds the lock' "$T/logs/T1-skipped.log"
check "a held lock starts no rman" test ! -e "$T/rman.log"

reset 'PHYSICAL STANDBY' true DISABLED 7 "$fresh"
seq 1 300 | sed 's/^/x /' >"$T/logs/T1-skipped.log"
run arch >"$T/out" 2>&1
check "skipped log is cut to its last 200 lines (plus the new one)" test "$(wc -l <"$T/logs/T1-skipped.log")" = 201
touch -d '40 days ago' "$T/logs/old.log"
run arch >"$T/out" 2>&1
check "logs older than 30 days go before the role check" test ! -e "$T/logs/old.log"

# --- stubs for rman.sh --------------------------------------------------------
mkdir -p "$T/bin" "$T/vm"
cat >"$T/bin/crontab" <<'EOF'
#!/bin/bash
f=$STUB/vm/crontab
case $1 in
  -l) if [ -e "$STUB/vm/crontab-fail" ]; then echo "crontab: cannot open /var/spool/cron: I/O error" >&2; exit 1; fi
      if [ -e "$f" ]; then cat "$f"; else echo "no crontab for oracle" >&2; exit 1; fi ;;
  -) cat >"$f" ;;
esac
EOF
chmod +x "$T/bin/crontab"
cat >"$T/bin/ssh" <<'EOF'
#!/bin/bash
cmd=${*: -1}
cmd=${cmd#sudo -u oracle }
case $cmd in
  *" configure"*) echo "configure-called" >>"$STUB/vm/configure.log"; exit 0 ;;
esac
PATH="$STUB/bin:$PATH" eval "$cmd"
EOF
printf '#!/bin/bash\n[ "$*" = "-p /home/oracle/scripts" ] || exec /bin/mkdir "$@"\n' >"$T/bin/mkdir"
chmod +x "$T/bin/ssh" "$T/bin/mkdir"
export SSH_BIN="$T/bin/ssh" SCRIPT_DEST="$T/vm/rman-backup.sh"
cdb26='# obenhub: CDB26 RMAN, recovery window 7 days
30 1 * * 0 /home/oracle/scripts/rman-backup.sh CDB26 level0
30 1 * * 1-6 /home/oracle/scripts/rman-backup.sh CDB26 level1
15 */4 * * * /home/oracle/scripts/rman-backup.sh CDB26 arch'
printf '%s\n' "$cdb26" >"$T/vm/crontab"
cp "$T/vm/crontab" "$T/vm/crontab.orig"
dest=$SCRIPT_DEST

touch "$T/vm/crontab-fail"
rc=0; "$rmansh" ora-au-lab >"$T/out" 2>&1 || rc=$?
check "crontab -l failing aborts rman.sh" test "$rc" != 0
check "crontab -l failing leaves the crontab alone" cmp -s "$T/vm/crontab" "$T/vm/crontab.orig"
rm "$T/vm/crontab-fail"

"$rmansh" ora-au-lab >"$T/out" 2>&1 || { cat "$T/out" >&2; exit 1; }
check "first run adds three tagged lines" test "$(grep -c " # obenhub: CDB19\$" "$T/vm/crontab")" = 3
check "CDB26 lines are byte-identical" cmp -s <(head -n 4 "$T/vm/crontab") "$T/vm/crontab.orig"
check "first run calls configure" has configure-called "$T/vm/configure.log"
"$rmansh" ora-au-lab >"$T/out" 2>&1 || { cat "$T/out" >&2; exit 1; }
check "second run: crontab unchanged" has 'crontab unchanged' "$T/out"
check "second run: script unchanged" has 'unchanged' "$T/out"

# a hand-edited managed line and a legacy untagged line are replaced, not duplicated
sed -i "s#^45 1 \* \* 0 .*#0 3 * * 0 $dest CDB19 level0 \# obenhub: CDB19#" "$T/vm/crontab"
echo "45 1 * * 1-6 $dest CDB19 level1" >>"$T/vm/crontab"
echo "# unmanaged note" >>"$T/vm/crontab"
"$rmansh" ora-au-lab >"$T/out" 2>&1 || { cat "$T/out" >&2; exit 1; }
check "hand-edited line: three tagged lines, no duplicate" test "$(grep -c "CDB19 " "$T/vm/crontab")" = 3
check "hand-edited line: back to the wanted schedule" has "^45 1 \* \* 0 $dest CDB19 level0 # obenhub: CDB19\$" "$T/vm/crontab"
check "unmanaged line kept" has '^# unmanaged note$' "$T/vm/crontab"
check "CDB26 lines still byte-identical" cmp -s <(head -n 4 "$T/vm/crontab") "$T/vm/crontab.orig"

rm -f "$T/vm/crontab"
"$rmansh" ora-dg-stby >"$T/out" 2>&1 || { cat "$T/out" >&2; exit 1; }
check "no crontab at all counts as empty" test "$(grep -c " # obenhub: CDB19_STBY\$" "$T/vm/crontab")" = 3

exit "$fail"
