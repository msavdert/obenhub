#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034
# Helpers of the two RMAN backup scenarios (backup-failed.sh, backup-stale.sh):
# the age and the last job of the CDB19 primary's archived log backups, the
# managed backup script and its cron schedule. Source it after lib.sh; do not
# run it.
#
# The age is read the way the oracledb-backup pack reads it
# (packs/oracledb-backup/queries.yaml): the newest END_TIME of a job in
# V$RMAN_BACKUP_JOB_DETAILS with status COMPLETED or COMPLETED WITH WARNINGS
# and input type ARCHIVELOG, DB FULL or DB INCR (a level 0 or 1 run backs up
# archived logs too).

BK_SCRIPT=/home/oracle/scripts/rman-backup.sh
BK_LOGDIR=/home/oracle/rman-logs
# cron of lab/oracle/scripts/rman.sh: archived logs at :45 of hours 0, 4, ...
# 20, level 0 or 1 at 01:45. A job of either kind started within BK_NEAR_BEFORE
# minutes before to BK_NEAR_AFTER minutes after those times would reset the age
# or collide with a manual run (the level jobs run about 6 minutes on the lab
# data: 326 s measured on 2026-11-14).
BK_NEAR_BEFORE=8
BK_NEAR_AFTER=15

# arch_age: seconds since the last completed archived log backup; "none" when
# there is no such job
arch_age() {
  ora_sql "$PRIMARY_SID" <<<"SELECT NVL(TO_CHAR(ROUND((SYSDATE - MAX(end_time)) * 86400)), 'none') FROM v\$rman_backup_job_details WHERE status IN ('COMPLETED', 'COMPLETED WITH WARNINGS') AND input_type IN ('ARCHIVELOG', 'DB FULL', 'DB INCR');" | tr -d '[:space:]'
}
# last_arch_job: "<status> <seconds since it started>" of the newest job of the
# archivelog kind that is not running: ARCHIVELOG or a database job, newest by
# START_TIME then SESSION_KEY (the one oracledb.backup.failed reads for
# archivelog, packs/oracledb-backup/queries.yaml)
last_arch_job() {
  ora_sql "$PRIMARY_SID" <<<"SELECT status || ' ' || ROUND((SYSDATE - start_time) * 86400) FROM (SELECT status, start_time FROM v\$rman_backup_job_details WHERE input_type IN ('ARCHIVELOG', 'DB FULL', 'DB INCR') AND status NOT LIKE 'RUNNING%' ORDER BY start_time DESC, session_key DESC) WHERE ROWNUM = 1;" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}
# host_minute_of_day: the local time of the primary VM (cron's clock) as
# minutes since midnight
host_minute_of_day() {
  local t; t=$(rn "$PRIMARY_HOST" date '+%H %M') || return 1
  awk '{printf "%d\n", $1 * 60 + $2}' <<<"$t"
}
# cron_near MINUTE: succeeds when a managed cron job fires within the window
# around that minute of the day (also across midnight)
cron_near() {
  local t=$1 f d
  for f in 45 105 285 525 765 1005 1245; do
    for d in -1440 0 1440; do
      [ "$((t - f - d))" -ge "-$BK_NEAR_BEFORE" ] && [ "$((t - f - d))" -le "$BK_NEAR_AFTER" ] && return 0
    done
  done
  return 1
}
# arch_status: the status words of the newest archived log job ("" when none)
arch_status() { last_arch_job | sed 's/ [0-9]*$//'; }
arch_job_good() { case $(arch_status) in COMPLETED | 'COMPLETED WITH WARNINGS') true ;; *) false ;; esac; }
# arch_done_since EPOCH: the newest archived log job completed and started at or
# after EPOCH (a job from before it does not count)
arch_done_since() {
  local j s; j=$(last_arch_job) || return 1
  s=${j##* }
  arch_job_good && [[ $s =~ ^[0-9]+$ ]] && [ "$s" -le "$(($(date +%s) - $1))" ]
}
# cron_clear: no managed cron job fires within the window around now (VM clock)
cron_clear() { local m; m=$(host_minute_of_day) && ! cron_near "$m"; }
# wait_cron_clear: wait up to BK_WAIT_CLEAR seconds for the window to pass
# instead of refusing (a refusal would abort a whole suite); the window is
# BK_NEAR_BEFORE + BK_NEAR_AFTER = 23 minutes at most
BK_WAIT_CLEAR=1500
wait_cron_clear() {
  host_minute_of_day >/dev/null || { PRE_ERR="cannot read the clock of $PRIMARY_HOST"; return 1; }
  cron_clear && return 0
  log "a managed backup cron job fires near now on $PRIMARY_HOST: waiting up to ${BK_WAIT_CLEAR}s for the window to pass"
  wait_until "$BK_WAIT_CLEAR" "no managed backup cron job near now" cron_clear
}
# run_arch_backup: the managed script, "arch" kind, as cron runs it (it takes
# the same lock; when another run holds it, it logs a skip and exits 0)
run_arch_backup() {
  ( REMOTE_TIMEOUT=900; ora_sh "$PRIMARY_SID" "$BK_SCRIPT $PRIMARY_SID arch" </dev/null )
}
# bk_script_present: the managed script is on the primary VM and executable
bk_script_present() { rn "$PRIMARY_HOST" test -x "$BK_SCRIPT"; }
