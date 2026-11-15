#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034
# Scenario backup-failed: one RMAN archived log backup job of the CDB19 primary on ora-au-lab fails, then one
# successful job of the same kind runs (ADR 0008 decision 8, stale and failed backups).
#
# Fault: after a log switch (so that at least one archived log exists), as the oracle user, under the lock
# the managed backup script uses (/home/oracle/rman-logs/.CDB19.lock, so cron's own job skips instead of
# running at the same time):
#     backup archivelog all format '/nonexistent-obenhub/arch-%U';
# The destination directory does not exist, so RMAN cannot create the backup piece and the job ends in error.
# Why this fault: it is the smallest one that makes a job fail. Nothing is stopped, no parameter, file,
# permission or cron line changes, the backup script and the recovery area are not touched, and a failed job
# deletes nothing (there is no DELETE INPUT here, unlike the managed job). The only footprint is one failed job
# row in the controlfile (V$RMAN_BACKUP_JOB_DETAILS keeps it for control_file_record_keep_time, 21 days on the
# lab) and one log file in /home/oracle/rman-logs; the failed row is not removed by the revert and is part of
# the evidence. A backup piece that cannot be created is an error of the BACKUP command (RMAN-03009, with
# ORA-19504 on the piece); that this makes the job row FAILED, not COMPLETED WITH ERRORS, is an assumption
# until a run shows it: the scenario records the job status it reads and fails when it is neither, because
# the rule reads exactly those two (lab/packs/oracledb-backup/queries.yaml). ASSUMPTION: not read in the
# Oracle Database 19c Backup and Recovery Reference (BACKUP, FORMAT) or the 19c Database Reference
# (V$RMAN_BACKUP_JOB_DETAILS); the first run is the check. Alternatives left out on purpose: making the
# managed script's backup directory unwritable (changes the lab's files and affects cron's real jobs),
# filling the recovery area (the archiver-stuck scenario, breaks redo transport), stopping the database.
#
# Expectation, from lab/packs/oracledb-backup/rules.yml: oracledb.backup.failed{kind=archivelog} is 1 from
# the primary's receiver as soon as the failed job is the newest finished job of its kind, and
# OracleBackupFailed (for: 2m) fires. Revert: the managed script's own archived log backup
# (rman-backup.sh CDB19 arch, the cron command: the job of the same kind), which succeeds, so the newest
# finished job is not failed and the alert resolves. The revert is idempotent and runs on every exit path.
# Guard: waits up to 25 min for the minutes around a managed cron job to pass (lib-backup.sh), refuses when the managed script
# is missing, or when the newest archived log job is already failed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-backup.sh"

EXPECT=("OracleBackupFailed:$PRIMARY_SID")
ALLOW=()
DETECT_TIMEOUT=420
DETECT_DEADLINE=420
HOLD_AFTER_DETECT=30
RESOLVE_TIMEOUT=600

FAIL_FORMAT=/nonexistent-obenhub/arch-%U
TRIED="" START_AT="" FAILED_AT="" RESTORED_AT=""
AGE_BEFORE="" AGE_AFTER="" JOB_BEFORE="" JOB_FAILED="" JOB_AFTER=""
RMAN_RC="" RMAN_CODES=null FAIL_LOG="" REVERT_RUNS=0
SERIES_AT_ALERT=null

# one failing RMAN run under the lock of the managed script; exit 75 when the lock is held
read -r -d '' FAIL_RUN <<'FAIL_EOF'
exec 9>"$LOGDIR/.$ORACLE_SID.lock"
flock -n 9 || { echo "lock held"; exit 75; }
cd "$LOGDIR" || exit 1
rman target / log="$LOGFILE" <<RMAN_EOF
backup archivelog all format '$FMT';
RMAN_EOF
echo "rman rc=$?"
FAIL_EOF

eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local j
  base_pre || return 1
  wait_cron_clear || { PRE_ERR=${PRE_ERR:-"a managed backup cron job still fires near now on $PRIMARY_HOST after ${BK_WAIT_CLEAR}s"}; return 1; }
  bk_script_present || { PRE_ERR="$BK_SCRIPT is missing or not executable on $PRIMARY_HOST (lab:oracle:rman)"; return 1; }
  cron_clear || { PRE_ERR="a managed backup cron job fires near now on $PRIMARY_HOST (a job would reset the alert)"; return 1; }
  AGE_BEFORE=$(arch_age)
  [[ $AGE_BEFORE =~ ^[0-9]+$ ]] || { PRE_ERR="no completed archived log backup on record on $PRIMARY_SID: '$AGE_BEFORE'"; return 1; }
  JOB_BEFORE=$(last_arch_job)
  j=${JOB_BEFORE% *}
  case $j in COMPLETED | 'COMPLETED WITH WARNINGS') ;; *) PRE_ERR="the newest archived log job of $PRIMARY_SID is '$JOB_BEFORE', not completed"; return 1 ;; esac
  [ "$(vm_query "max(last_over_time(oracledb.backup.failed{oracledb.backup.kind=\"archivelog\",service.instance.id=\"$PRIMARY_SID\"}[2m]))")" = 0 ] \
    || { PRE_ERR="the receiver does not report oracledb.backup.failed=0 for archivelog of $PRIMARY_SID (lab/packs/oracledb-backup/queries.yaml deployed? lab:oracle:collector)"; return 1; }
  log "archived log backup age $AGE_BEFORE s; newest archived log job: $JOB_BEFORE"
}

job_is_failed() { case $(arch_status) in FAILED* | 'COMPLETED WITH ERRORS') true ;; *) false ;; esac; }

inject() {
  local out ts
  TRIED=1
  log_switch || { FAILS+=("ALTER SYSTEM ARCHIVE LOG CURRENT failed"); return 1; }
  START_AT=$(date +%s)
  ts=$(date -u +%Y%m%dT%H%M%S)
  FAIL_LOG="$BK_LOGDIR/${PRIMARY_SID}-arch-obenhub-backup-failed-$ts.log"
  out=$( REMOTE_TIMEOUT=300 ora_sh "$PRIMARY_SID" "LOGDIR=$BK_LOGDIR LOGFILE=$FAIL_LOG FMT='$FAIL_FORMAT' bash -c $(printf '%q' "$FAIL_RUN")" </dev/null 2>&1 ) || true
  RMAN_RC=$(grep -E -o 'rman rc=[0-9]+' <<<"$out" | tail -n1 | cut -d= -f2)
  FAILED_AT=$(date +%s)
  log "failing job returned: rc '${RMAN_RC:-none}'"
  [ -n "$RMAN_RC" ] || { FAILS+=("the failing RMAN run did not report a status: $(tail -n 3 <<<"$out" | tr '\n' '|')"); return 1; }
  [ "$RMAN_RC" != 0 ] || { FAILS+=("the RMAN run with the nonexistent format directory returned 0"); return 1; }
  RMAN_CODES=$(rn "$PRIMARY_HOST" grep -E -o 'RMAN-[0-9]+|ORA-[0-9]+' "$FAIL_LOG" | sort | uniq -c \
    | sed -E 's/^ *([0-9]+) (.*)$/\1\t\2/' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {(.[1]): (.[0] | tonumber)}) | add // {}') || RMAN_CODES=null
  # the view is filled when the job ends; allow a few seconds
  wait_until 60 "the failed job in V\$RMAN_BACKUP_JOB_DETAILS" job_is_failed || true
  JOB_FAILED=$(last_arch_job)
  log "newest archived log job now: '$JOB_FAILED'; error codes in the RMAN log: $RMAN_CODES"
  job_is_failed || { FAILS+=("the failed RMAN run is not the newest archived log job as FAILED or COMPLETED WITH ERRORS: '$JOB_FAILED'"); return 1; }
  return 0
}

after_detect() {
  local f
  f=$(vm_query "max(last_over_time(oracledb.backup.failed{oracledb.backup.kind=\"archivelog\",service.instance.id=\"$PRIMARY_SID\"}[2m]))")
  SERIES_AT_ALERT=${f:-null}
  log "oracledb.backup.failed{archivelog} at the alert: ${f:-none}"
  [ "$f" = 1 ] || { FAILS+=("the receiver reports oracledb.backup.failed '${f:-none}' for archivelog after the alert, not 1"); return 1; }
}

revert() {
  local rc=0 i rs
  [ -n "$TRIED" ] || return 0
  rs=$(date +%s)
  for i in 1 2 3; do
    REVERT_RUNS=$i
    log_switch || true
    run_arch_backup >/dev/null 2>&1 || log "managed archived log backup returned an error (attempt $i)"
    RESTORED_AT=$(date +%s)
    # a run that found the lock held logs a skip and exits 0: look at the job, not the status
    if wait_until 30 "an archived log job completed since the revert began" arch_done_since "$rs"; then break; fi
    [ "$i" = 3 ] || { log "no completed job after the revert run $i, retrying in 30 s"; sleep 30; }
  done
  JOB_AFTER=$(last_arch_job)
  AGE_AFTER=$(arch_age)
  log "after the revert: newest archived log job '$JOB_AFTER', age $AGE_AFTER s, revert runs $REVERT_RUNS"
  arch_done_since "$rs" || { FAILS+=("no archived log job completed since the revert began, the newest is '$JOB_AFTER'"); rc=1; }
  return "$rc"
}

extra_checks() {
  [ -n "$START_AT" ] || return 0
  EXTRA_JSON=$(jq -n -c --argjson a "$START_AT" --argjson f "${FAILED_AT:-null}" --argjson r "${RESTORED_AT:-null}" \
    --argjson age0 "${AGE_BEFORE:-null}" --argjson age1 "${AGE_AFTER:-null}" --argjson codes "${RMAN_CODES:-null}" --argjson sa "${SERIES_AT_ALERT:-null}" \
    --arg rc "$RMAN_RC" --arg fmt "$FAIL_FORMAT" --arg log "$FAIL_LOG" --arg j0 "$JOB_BEFORE" --arg j1 "$JOB_FAILED" --arg j2 "$JOB_AFTER" --argjson runs "$REVERT_RUNS" \
    '{fault: "RMAN backup archivelog all with a nonexistent FORMAT directory", format: $fmt, rman_log: $log, rman_exit_status: ($rc | tonumber? // null),
      error_codes_in_rman_log: $codes, start_epoch: $a, failed_epoch: $f, revert_backup_done_epoch: $r,
      newest_archivelog_job: {before: $j0, after_fault: $j1, after_revert: $j2}, archivelog_backup_age_s: {before: $age0, after_revert: $age1},
      failed_series_at_alert: $sa, revert_runs: $runs}')
  log "extra: $EXTRA_JSON"
}

run_scenario backup-failed
