#!/bin/bash
# RMAN backup for one instance on this host (obenhub Oracle lab).
# usage: rman-backup.sh <SID> <level0|level1|arch|configure>
# Installed as /home/oracle/scripts/rman-backup.sh by lab/oracle/scripts/rman.sh
# (mise run lab:oracle:rman), which also converges the crontab and runs
# "configure" once per database.
# Retention is the RMAN configuration of the database (recovery window), so
# every backup run ends with "delete obsolete"; archived logs are deleted after
# they are backed up (archivelog deletion policy: applied on all standbys and
# backed up 1 times to disk).
# Only the PRIMARY database is backed up: on any other role (a Data Guard
# standby) a backup run logs one line and exits 0, so the same crontab can sit
# on both hosts of a pair and the backups follow the primary after a switchover
# or failover. Backups of the two sites are not visible to each other (no
# recovery catalog).
# Settings: on a primary of a Data Guard broker configuration
# (dg_broker_start TRUE; CDB26 has none and is left alone) every backup run
# first converges the RMAN settings and block change tracking below, because
# the RMAN configuration lives in each database's own controlfile: a promoted
# standby would otherwise run its first level 1 as an uncompressed level 0 with
# a redundancy 1 policy. The changes go to rman-logs/<SID>-configure.log.
#   primary:  retention recovery window of 7 days, controlfile autobackup on,
#             compressed backupset, archivelog deletion policy applied on all
#             standby backed up 1 times to disk, block change tracking in the
#             directory of datafile 1 (online, no restart)
#   standby:  only the archivelog deletion policy applied on all standby
# "configure" does that on any role, prints every change as "old -> new", and
# also sets control_file_record_keep_time to 21 days (spfile, online), so that
# the controlfile keeps the weekly level 0 chain and the one before it. It
# starts no backup. Overrides for tests: ORATAB, RMAN_LOG_DIR.
# shellcheck disable=SC2016  # $ in single quotes is SQL (v$ views), not shell
set -euo pipefail
sid=$1; kind=$2
export ORACLE_SID=$sid
ORATAB=${ORATAB:-/etc/oratab}
ORACLE_HOME=$(grep "^${sid}:" "$ORATAB" | cut -d: -f2)
export ORACLE_HOME PATH=$ORACLE_HOME/bin:$PATH
log_dir=${RMAN_LOG_DIR:-/home/oracle/rman-logs}
KEEP_TIME=21
mkdir -p "$log_dir"
cd "$log_dir"
case $kind in
  level0) cmd="backup incremental level 0 database plus archivelog delete all input;" ;;
  level1) cmd="backup incremental level 1 cumulative database plus archivelog delete all input;" ;;
  arch)   cmd="backup archivelog all not backed up 1 times delete all input;" ;;
  configure) cmd="" ;;
  *) echo "unknown kind $kind" >&2; exit 2 ;;
esac

# log rotation first, so that it also happens on a standby that only skips:
# RMAN logs after 30 days; the skipped log (appended to) keeps its last 200 lines
find "$log_dir" -name '*.log' -mtime +30 -delete
skipped=$log_dir/${sid}-skipped.log
if [ -f "$skipped" ] && [ "$(wc -l <"$skipped")" -gt 200 ]; then
  tail -n 200 "$skipped" >"$skipped.tmp" && mv "$skipped.tmp" "$skipped"
fi

# one run per SID at a time
exec 9>"$log_dir/.${sid}.lock"
if ! flock -n 9; then
  if [ "$kind" = configure ]; then echo "$sid: another run holds the lock" >&2; exit 1; fi
  echo "$(date +%Y-%m-%dT%H:%M:%S) $sid $kind skipped: another run holds the lock" | tee -a "$skipped"
  exit 0
fi

# q <sql>: first non-empty output line of one statement as sysdba
q() {
  { printf 'set heading off feedback off pagesize 0 linesize 500\n%s\n' "$1" | sqlplus -s / as sysdba || true; } |
    tr -d '\r' | sed -e 's/^ *//' -e 's/ *$//' | { grep -v '^$' || true; } | head -n 1
}

# converge <role> <with_keep_time>: the settings of the header. Prints
# "unchanged: ..." or "change: <old> -> <new>" per setting; fails when RMAN or
# SQL*Plus refuses one.
converge() {
  local role=$1 keep=$2 show out i topic old
  local -a pats=() cmds=()
  show=$(echo 'show all;' | rman target / | tr -d '\r')
  if [ "$role" = PRIMARY ]; then
    pats+=('^CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;')
    cmds+=('CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;')
    pats+=('^CONFIGURE CONTROLFILE AUTOBACKUP ON;')
    cmds+=('CONFIGURE CONTROLFILE AUTOBACKUP ON;')
    pats+=('^CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET ')
    cmds+=('CONFIGURE DEVICE TYPE DISK BACKUP TYPE TO COMPRESSED BACKUPSET;')
    pats+=('^CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;')
    cmds+=('CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;')
  else
    pats+=('^CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;')
    cmds+=('CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;')
  fi
  for i in "${!pats[@]}"; do
    if grep -Eq -- "${pats[$i]}" <<<"$show"; then
      echo "[$sid] unchanged: ${cmds[$i]}"
    else
      topic=$(sed -E 's/^(CONFIGURE (RETENTION POLICY|CONTROLFILE AUTOBACKUP|DEVICE TYPE DISK|ARCHIVELOG DELETION POLICY)).*/\1/' <<<"${cmds[$i]}")
      old=$(grep -F -- "$topic" <<<"$show" | { grep -v FORMAT || true; } | head -n 1)
      echo "[$sid] change: $old -> ${cmds[$i]}"
      out=$(echo "${cmds[$i]}" | rman target / | tr -d '\r')
      grep -q 'successfully stored' <<<"$out" || { echo "$out" >&2; echo "[$sid] ${cmds[$i]} failed" >&2; return 1; }
    fi
  done
  if [ "$role" = PRIMARY ]; then
    local bct dir
    bct=$(q 'select status from v$block_change_tracking;')
    if [ "$bct" = ENABLED ]; then
      echo "[$sid] unchanged: block change tracking enabled"
    else
      dir=$(q 'select name from v$datafile where file# = 1;')
      dir=$(dirname "$dir")
      [ -d "$dir" ] || { echo "[$sid] datafile directory $dir does not exist" >&2; return 1; }
      echo "[$sid] change: block change tracking ${bct:-unknown} -> ENABLED in $dir/bct.chg"
      printf "whenever sqlerror exit 1\nalter database enable block change tracking using file '%s/bct.chg';\n" "$dir" | sqlplus -s / as sysdba
    fi
  fi
  if [ "$keep" = 1 ]; then
    old=$(q "select value from v\$parameter where name = 'control_file_record_keep_time';")
    if [ "$old" = "$KEEP_TIME" ]; then
      echo "[$sid] unchanged: control_file_record_keep_time $KEEP_TIME"
    else
      echo "[$sid] change: control_file_record_keep_time $old -> $KEEP_TIME"
      printf "whenever sqlerror exit 1\nalter system set control_file_record_keep_time = %s scope = both;\n" "$KEEP_TIME" | sqlplus -s / as sysdba
    fi
  fi
}

role=$(q 'select database_role from v$database;')
if [ "$kind" = configure ]; then
  case $role in
    PRIMARY|"PHYSICAL STANDBY") converge "$role" 1; exit 0 ;;
    *) echo "[$sid] unexpected database role: ${role:-none}" >&2; exit 1 ;;
  esac
fi
if [ "$role" != PRIMARY ]; then
  # a role is upper-case letters and spaces (PHYSICAL STANDBY); anything else
  # is an error text (instance down, not mounted): fail so that cron reports it
  case $role in
    "" | *[!A-Z\ ]*) echo "cannot read the database role of $sid: ${role:-no output}" >&2; exit 1 ;;
  esac
  echo "$(date +%Y-%m-%dT%H:%M:%S) $sid $kind skipped: role is $role, not PRIMARY" | tee -a "$skipped"
  exit 0
fi
if [ "$(q "select lower(value) from v\$parameter where name = 'dg_broker_start';")" = true ]; then
  { date +%Y-%m-%dT%H:%M:%S; converge PRIMARY 0; } >>"$log_dir/${sid}-configure.log" 2>&1 ||
    { echo "settings of $sid could not be converged, see $log_dir/${sid}-configure.log" >&2; exit 1; }
fi
log=$log_dir/${sid}-${kind}-$(date +%Y%m%dT%H%M%S).log
rman target / log="$log" <<EOF
$cmd
delete noprompt obsolete;
crosscheck archivelog all;
delete noprompt expired archivelog all;
EOF
