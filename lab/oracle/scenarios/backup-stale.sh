#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034
# Scenario backup-stale (LONG, not in suite.txt): the archived log backup cron line of the CDB19 primary on
# ora-au-lab is paused until OracleBackupStale fires for kind archivelog, then restored, and one archived log
# backup runs so that the alert resolves (ADR 0008 decision 8).
#
# Fault: lab/oracle/files/cron-pause.sh, installed as /usr/local/sbin/obenhub-cron-pause on ora-au-lab, comments
# out (prefix "#obenhub-paused# ") the one crontab line of the oracle user that ends in
# "rman-backup.sh CDB19 arch # obenhub: CDB19" (schedule "45 */4 * * *", lab/oracle/scripts/rman.sh). Nothing else
# changes: no RMAN, database or file change. The daily level 0 or 1 line (01:45) is NOT paused and it also backs up
# archived logs, so the age series (which counts those jobs too, packs/oracledb-backup/queries.yaml) resets
# when it ends; the scenario reads the next 01:45 on the VM's clock and, if it falls before the alert would fire,
# computes the fire time from the end of that job (DAILY_JOB_S, 326 s measured for a level 0 on 2026-11-14,
# rounded up) and refuses to start when that is beyond the wait cap.
#
# Timing: OracleBackupStale compares oracledb.backup.age{kind=archivelog} with obenhub.backup_age.limit (18000 s),
# for 1m. The age counts from the END of the last completed job, so the alert fires at
# (last job end) + limit + 1 m + collection and evaluation delay, not limit after the start. The scenario reads the
# age from V$RMAN_BACKUP_JOB_DETAILS at the start, prints the expected fire time, and waits at most
# (expected fire - now) + WAIT_MARGIN, capped at WAIT_CAP (6 h); the pre-flight refuses to start when the cap is
# not enough. The limit is a recording rule in lab/oracle/mon/vmalert/inventory.yml (one constant series per kind,
# no variable behind it): a trial cannot lower it without editing that file, so the trial mode below does not
# exercise the alert (see TRIAL).
#
# Revert, on every exit path (the shared exit trap runs it on normal end, failure, timeout, INT and TERM): restore the
# crontab line on ora-au-lab with obenhub-cron-pause restore (idempotent: a line already there is left, the paused
# form is replaced in place, a missing one is appended; the whole crontab is compared with the copy taken before the
# pause and the result is recorded), remove the safety net, and run one archived log backup with the managed script
# (rman-backup.sh CDB19 arch), so the age series restarts and the alert resolves.
#
# Safety net, installed on ora-au-lab BEFORE the line is paused, for the case that this script (or the box it runs
# on) dies without running the revert: the systemd timer obenhub-cron-restore.timer (root, enabled) restores the
# line at NET_DEADLINE = start + 7 h (OnCalendar, Persistent=true) and also 5 min after every boot of the VM
# (OnBootSec; the service restores only once the deadline has passed), and repeats every 15 min after a failed restore (OnUnitInactiveSec) until one succeeds. It survives a reboot of ora-au-lab; a deadline
# missed while the VM was down is restored within 5 min of the boot (design, not tested with a reboot). It does not
# run a backup: the next cron line fire (at most 4 h later) does. Normal restore removes it. If the script is killed
# with SIGKILL, the line stays paused, and the alert stays firing, until the deadline: finish by hand with
# "sudo /usr/local/sbin/obenhub-cron-pause restore" on ora-au-lab.
#
# TRIAL: BACKUP_STALE_TRIAL_SECONDS=N (60 to 1800) holds the pause for N seconds instead of waiting for the alert
# and expects no alert. It verifies the mechanics: pause, safety net installed, the age keeps growing and no
# archived log backup completes, restore, crontab identical to the copy, safety net removed, one backup, age reset.
# The pre-flight then refuses to start unless the age plus N plus 15 min is below the limit (the real alert must
# not fire) and the daily level job (01:45) does not fall inside the window; it checks nothing else about the
# window, because the paused arch line is skipped by design (a :45 fire inside the window is the point of the
# pause) and a trial that spans one is fine. Both runs wait up to 25 min for the minutes around a managed cron
# job to pass before they start. Without the variable the run is the real one. Only the trial has run so far;
# the real path (expected fire time, the wait for the alert, after_detect) has not.
#
# Start the real run detached (nobody watches it):
#   setsid nohup mise run lab:oracle:scenario backup-stale > ~/work/obenhub-runs/backup-stale-$(date +%Y%m%d).log 2>&1 &
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-backup.sh"

TRIAL=${BACKUP_STALE_TRIAL_SECONDS:-}
if [ -n "$TRIAL" ]; then
  [[ $TRIAL =~ ^[0-9]+$ ]] && [ "$TRIAL" -ge 60 ] && [ "$TRIAL" -le 1800 ] || { echo "BACKUP_STALE_TRIAL_SECONDS must be 60 to 1800, got '$TRIAL'" >&2; exit 2; }
  EXPECT=()
else
  EXPECT=("OracleBackupStale:$PRIMARY_SID")
fi
ALLOW=()
HOLD_AFTER_DETECT=30
RESOLVE_TIMEOUT=900

NET_SRC="$LAB_DIR/files/cron-pause.sh"
NET_BIN=/usr/local/sbin/obenhub-cron-pause
WAIT_CAP=21600
WAIT_MARGIN=1200
NET_SECONDS=25200
DAILY_JOB_S=420
# the daily job counts as before the fire when it is within this margin of it: the rule
# holds for 1 m and the receiver and vmalert add their own intervals. A fire time within a
# few minutes of 01:45 may still fire early, or briefly before the job ends and the age
# resets; that is harmless, the alert is detected either way and the wait budget covers it.
CROSS_MARGIN=300
DEFAULT_LIMIT=18000

HOLD_PID="" NET_INSTALLED="" TRIED="" START_AT="" PAUSED_AT="" RESTORED_AT="" BACKUP_AT=""
LIMIT="" AGE0="" AGE_END="" AGE_AFTER="" FIRE_IN="" EXPECTED_AT="" WAIT_S="" NET_DEADLINE="" DAILY_AT="" CROSSES=false
CRON_SHA0="" CRON_SHA1="" PAUSE_OUT="" RESTORE_OUT="" STATUS_PAUSED="" STATUS_AFTER="" CRON_SAME=""
TRIAL_ROW=null SERIES_AT_ALERT=null RS=0

cp_run() { rn "$PRIMARY_HOST" "$NET_BIN" "$@"; }
cron_sha() { timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$PRIMARY_HOST" 'sudo runuser -u oracle -- crontab -l 2>/dev/null | sha256sum | cut -c1-16'; }
net_install_bin() {
  [ -s "$NET_SRC" ] || return 1
  timeout --foreground "$REMOTE_TIMEOUT" ssh "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo tee $NET_BIN >/dev/null && sudo chmod 755 $NET_BIN && sudo chown root:root $NET_BIN" <"$NET_SRC"
}
net_is_gone() {
  local s; s=$(cp_run status) || return 1
  grep -q '^state: none' <<<"$s" && ! grep -Eq '^timer: .*(enabled|/ active)' <<<"$s" && grep -q 'crontab: 0$' <<<"$s"
}
# active managed archived log lines (a line starting with # is not counted)
managed_lines() {
  timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo runuser -u oracle -- crontab -l 2>/dev/null | grep -Ec '^[^#].*rman-backup\\.sh $PRIMARY_SID arch # obenhub: $PRIMARY_SID\$' || true"
}
paused_lines() {
  timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo runuser -u oracle -- crontab -l 2>/dev/null | grep -c '^#obenhub-paused# ' || true"
}
age_series() { vm_query "max(last_over_time(oracledb.backup.age{oracledb.backup.kind=\"archivelog\",service.instance.id=\"$PRIMARY_SID\"}[2m]))"; }
limit_series() { vm_query 'max(obenhub.backup_age.limit{oracledb.backup.kind="archivelog"})'; }

eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local now s d1 d2 sa
  base_pre || return 1
  wait_cron_clear || { PRE_ERR=${PRE_ERR:-"a managed backup cron job still fires near now on $PRIMARY_HOST after ${BK_WAIT_CLEAR}s"}; return 1; }
  bk_script_present || { PRE_ERR="$BK_SCRIPT is missing or not executable on $PRIMARY_HOST (lab:oracle:rman)"; return 1; }
  [ -s "$NET_SRC" ] || { PRE_ERR="$NET_SRC is missing"; return 1; }
  cron_clear || { PRE_ERR="a managed backup cron job fires near now on $PRIMARY_HOST (the age would change during the start)"; return 1; }
  s=$(paused_lines) || { PRE_ERR="cannot read the crontab of oracle on $PRIMARY_HOST"; return 1; }
  [ "$s" = 0 ] || { PRE_ERR="the crontab of oracle on $PRIMARY_HOST holds $s paused line(s) (#obenhub-paused#): run $NET_BIN restore there"; return 1; }
  s=$(managed_lines) || { PRE_ERR="cannot read the crontab of oracle on $PRIMARY_HOST"; return 1; }
  [ "$s" = 1 ] || { PRE_ERR="expected exactly one managed archived log line for $PRIMARY_SID in the crontab of oracle, found '$s'"; return 1; }
  s=$(rn "$PRIMARY_HOST" sh -c "test -e /var/lib/obenhub-cron-pause && echo yes || echo no") || { PRE_ERR="cannot read the pause state on $PRIMARY_HOST"; return 1; }
  [ "$s" = no ] || { PRE_ERR="a pause is still active on $PRIMARY_HOST (/var/lib/obenhub-cron-pause): run $NET_BIN restore there"; return 1; }
  AGE0=$(arch_age)
  [[ $AGE0 =~ ^[0-9]+$ ]] || { PRE_ERR="no completed archived log backup on record on $PRIMARY_SID: '$AGE0'"; return 1; }
  sa=$(age_series)
  [[ $sa =~ ^[0-9]+$ ]] && [ "$((sa - AGE0))" -ge -150 ] && [ "$((sa - AGE0))" -le 150 ] || { PRE_ERR="the receiver's oracledb.backup.age archivelog '${sa:-none}' does not match the database's $AGE0 s (packs/oracledb-backup/queries.yaml deployed? lab:oracle:collector)"; return 1; }
  LIMIT=$(limit_series)
  LIMIT=${LIMIT%.*}
  if [ -z "$LIMIT" ]; then LIMIT=$DEFAULT_LIMIT; log "no obenhub.backup_age.limit series for archivelog, the pack default $LIMIT applies"; fi
  [[ $LIMIT =~ ^[0-9]+$ ]] || { PRE_ERR="obenhub.backup_age.limit for archivelog is not a number: '$LIMIT'"; return 1; }
  [ "$AGE0" -lt "$LIMIT" ] || { PRE_ERR="the archived log backup age $AGE0 s is already above the limit $LIMIT s"; return 1; }
  now=$(date +%s)
  d1=$(rn "$PRIMARY_HOST" date -d 'today 01:45' +%s) || { PRE_ERR="cannot read the clock of $PRIMARY_HOST"; return 1; }
  d2=$(rn "$PRIMARY_HOST" date -d 'tomorrow 01:45' +%s) || { PRE_ERR="cannot read the clock of $PRIMARY_HOST"; return 1; }
  if [ "$d1" -gt "$now" ]; then DAILY_AT=$d1; else DAILY_AT=$d2; fi
  if [ -n "$TRIAL" ]; then
    [ "$((AGE0 + TRIAL + 900))" -lt "$LIMIT" ] || { PRE_ERR="trial: age $AGE0 s + $TRIAL s + 900 s is not below the limit $LIMIT s, the real alert would fire"; return 1; }
    [ "$DAILY_AT" -gt "$((now + TRIAL + 900))" ] || { PRE_ERR="trial: the daily level job (01:45) falls inside the trial window"; return 1; }
    FIRE_IN=$((TRIAL))
    WAIT_S=$((TRIAL + 900))
  else
    FIRE_IN=$((LIMIT - AGE0))
    if [ "$DAILY_AT" -lt "$((now + FIRE_IN + CROSS_MARGIN))" ]; then
      CROSSES=true
      FIRE_IN=$((DAILY_AT - now + DAILY_JOB_S + LIMIT))
    fi
    WAIT_S=$((FIRE_IN + 60 + WAIT_MARGIN))
    [ "$WAIT_S" -le "$WAIT_CAP" ] || { PRE_ERR="the alert is expected $((FIRE_IN / 60)) min after the start (limit $LIMIT s, age $AGE0 s, daily level job at $(date -u -d "@$DAILY_AT" +%H:%M)Z, crossed: $CROSSES); the wait would be $WAIT_S s, above the cap $WAIT_CAP s: start earlier in the 4 h cycle or after the daily job"; return 1; }
  fi
  EXPECTED_AT=$((now + FIRE_IN + 60))
  DETECT_TIMEOUT=$WAIT_S
  DETECT_DEADLINE=$WAIT_S
  log "limit $LIMIT s; archived log backup age $AGE0 s; daily job at $(date -u -d "@$DAILY_AT" '+%F %TZ') (before the fire: $CROSSES)"
  if [ -n "$TRIAL" ]; then log "TRIAL mode: hold $TRIAL s, no alert expected"
  else log "expected OracleBackupStale about $(date -u -d "@$EXPECTED_AT" '+%F %TZ') ($((FIRE_IN + 60)) s from now); wait at most $WAIT_S s"; fi
}

inject() {
  local out
  TRIED=1
  START_AT=$(date +%s)
  NET_DEADLINE=$((START_AT + NET_SECONDS))
  CRON_SHA0=$(cron_sha) || { FAILS+=("cannot read the crontab of oracle on $PRIMARY_HOST"); return 1; }
  net_install_bin || { FAILS+=("installing $NET_BIN on $PRIMARY_HOST failed"); return 1; }
  NET_INSTALLED=1
  PAUSE_OUT=$(cp_run pause "$PRIMARY_SID" arch "$NET_DEADLINE" 2>&1) || { FAILS+=("obenhub-cron-pause pause failed: $PAUSE_OUT"); return 1; }
  PAUSED_AT=$(date +%s)
  STATUS_PAUSED=$(cp_run status 2>&1 | tr '\n' '|')
  log "paused at $PAUSED_AT: $PAUSE_OUT; safety net restores at $(date -u -d "@$NET_DEADLINE" '+%F %TZ'); status: $STATUS_PAUSED"
  grep -q 'state: paused' <<<"$STATUS_PAUSED" || { FAILS+=("pause state not reported after the pause: $STATUS_PAUSED"); return 1; }
  grep -q 'timer: enabled / active' <<<"$STATUS_PAUSED" || { FAILS+=("safety net timer not enabled and active after the pause: $STATUS_PAUSED"); return 1; }
  if [ -n "$TRIAL" ]; then
    sleep "$TRIAL" & HOLD_PID=$!
    wait "$HOLD_PID"
    HOLD_PID=""
    local a s
    a=$(arch_age); s=$(age_series)
    AGE_END=$a
    TRIAL_ROW=$(jq -n -c --arg a "$a" --arg s "$s" --argjson held "$TRIAL" --argjson a0 "$AGE0" '{held_s: $held, age_db_s: ($a | tonumber? // null), age_series_s: ($s | tonumber? // null), age_at_start_s: $a0}')
    log "trial hold over: $TRIAL_ROW"
    [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge "$((AGE0 + TRIAL - 30))" ] || FAILS+=("trial: the archived log backup age is '$a' after $TRIAL s, expected at least $((AGE0 + TRIAL - 30)): a backup completed during the pause")
  fi
  return 0
}

after_detect() {
  local rc=0 a s
  a=$(arch_age); s=$(age_series)
  AGE_END=$a
  SERIES_AT_ALERT=${s:-null}
  log "at the alert: database age ${a:-none} s, receiver series ${s:-none} s, limit $LIMIT s"
  [[ $a =~ ^[0-9]+$ ]] && [ "$a" -gt "$LIMIT" ] || { FAILS+=("the database's archived log backup age '${a:-none}' is not above the limit $LIMIT s at the alert"); rc=1; }
  STATUS_PAUSED=$(cp_run status 2>&1 | tr '\n' '|')
  grep -q 'state: paused' <<<"$STATUS_PAUSED" || { FAILS+=("the pause is not active at the alert: $STATUS_PAUSED"); rc=1; }
  return "$rc"
}

# the age is reset by a job that completed after the revert began, not by one from before
age_reset() { arch_done_since "$RS"; }
revert() {
  local rc=0 i
  [ -n "$TRIED" ] && [ -n "$NET_INSTALLED" ] || return 0
  [ -z "$HOLD_PID" ] || kill "$HOLD_PID" 2>/dev/null
  RS=$(date +%s)
  for i in 1 2 3; do
    if RESTORE_OUT=$(cp_run restore 2>&1); then break; fi
    log "restore attempt $i failed: $RESTORE_OUT"
    RESTORE_OUT=""
    [ "$i" = 3 ] || sleep 15
  done
  if [ -z "$RESTORE_OUT" ]; then
    FAILS+=("obenhub-cron-pause restore failed three times: the cron line stays paused and the safety net restores it at $(date -u -d "@${NET_DEADLINE:-0}" '+%F %TZ')")
    return 1
  fi
  RESTORED_AT=$(date +%s)
  RESTORE_OUT=$(tr '\n' '|' <<<"$RESTORE_OUT")
  CRON_SHA1=$(cron_sha) || CRON_SHA1=""
  [ -n "$CRON_SHA0" ] && [ "$CRON_SHA0" = "$CRON_SHA1" ] && CRON_SAME=true || CRON_SAME=false
  STATUS_AFTER=$(cp_run status 2>&1 | tr '\n' '|')
  log "restored: $RESTORE_OUT crontab hash before $CRON_SHA0 after $CRON_SHA1; status: $STATUS_AFTER"
  [ "$CRON_SAME" = true ] || { FAILS+=("the crontab of oracle differs from the copy taken before the pause ($CRON_SHA0 vs ${CRON_SHA1:-unreadable})"); rc=1; }
  net_is_gone || { FAILS+=("the safety net or the pause state is still there after the restore: $STATUS_AFTER"); rc=1; }
  for i in 1 2 3; do
    log_switch || true
    run_arch_backup >/dev/null 2>&1 || log "managed archived log backup returned an error (attempt $i)"
    BACKUP_AT=$(date +%s)
    wait_until 30 "the archived log backup age reset" age_reset && break
    [ "$i" = 3 ] || { log "no completed backup after run $i, retrying in 30 s"; sleep 30; }
  done
  AGE_AFTER=$(arch_age)
  log "backup done; archived log backup age now $AGE_AFTER s"
  age_reset || { FAILS+=("no archived log backup completed after the revert began (age now '$AGE_AFTER' s)"); rc=1; }
  return "$rc"
}

extra_checks() {
  local starts starts_s=null delivered_s=null
  [ -n "$START_AT" ] || return 0
  starts=$(vl "_time:>$T_INJECT status:=firing commonLabels.alertname:=OracleBackupStale commonLabels.service_instance_id:=$PRIMARY_SID | sort by (_time) | limit 1 | fields alerts" 2>/dev/null \
    | jq -r '.alerts | fromjson | .[0].startsAt' 2>/dev/null | head -n1) || starts=""
  if [ -n "$starts" ] && [ "$starts" != null ]; then starts_s=$(date -u -d "$starts" +%s) || starts_s=null; fi
  [ -z "$T_DETECT" ] || delivered_s=$(date -u -d "$T_DETECT" +%s)
  EXTRA_JSON=$(jq -n -c --argjson t "$([ -n "$TRIAL" ] && echo true || echo false)" --argjson a "$START_AT" --argjson p "${PAUSED_AT:-null}" --argjson r "${RESTORED_AT:-null}" --argjson b "${BACKUP_AT:-null}" \
    --argjson limit "${LIMIT:-null}" --argjson age0 "${AGE0:-null}" --argjson ageend "${AGE_END:-null}" --argjson age1 "${AGE_AFTER:-null}" \
    --argjson fire_in "${FIRE_IN:-null}" --argjson exp "${EXPECTED_AT:-null}" --argjson wait "${WAIT_S:-null}" --argjson netdl "${NET_DEADLINE:-null}" --argjson daily "${DAILY_AT:-null}" --argjson cross "$CROSSES" \
    --argjson starts_s "$starts_s" --argjson delivered_s "$delivered_s" --argjson trial_row "${TRIAL_ROW:-null}" --argjson sa "${SERIES_AT_ALERT:-null}" \
    --arg same "$CRON_SAME" --arg h0 "$CRON_SHA0" --arg h1 "$CRON_SHA1" --arg po "$PAUSE_OUT" --arg ro "$RESTORE_OUT" --arg sp "$STATUS_PAUSED" --arg sf "$STATUS_AFTER" \
    '{trial_mode: $t, fault: "oracle crontab line of the archived log backup commented out", limit_s: $limit, archivelog_age_at_start_s: $age0, archivelog_age_at_end_of_pause_s: $ageend, archivelog_age_after_revert_s: $age1,
      start_epoch: $a, paused_epoch: $p, restored_epoch: $r, revert_backup_done_epoch: $b, expected_fire_in_s: $fire_in, expected_alert_epoch: $exp, wait_budget_s: $wait,
      safety_net_deadline_epoch: $netdl, daily_job_epoch: $daily, daily_job_before_fire: $cross, receiver_age_series_at_alert_s: $sa,
      alert: {starts_at_epoch: $starts_s, delivered_epoch: $delivered_s, delivered_minus_expected_s: (if $delivered_s != null and $exp != null then $delivered_s - $exp else null end)},
      crontab_hash_before: $h0, crontab_hash_after: $h1, crontab_identical: ($same == "true"), pause_output: $po, restore_output: $ro, status_paused: $sp, status_after: $sf, trial: $trial_row}')
  log "extra: $EXTRA_JSON"
}

run_scenario backup-stale
