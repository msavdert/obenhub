#!/usr/bin/env bash
# Scenario fsfo-failover: the CDB19 primary on ora-au-lab is aborted (SHUTDOWN ABORT as sysdba, no clean shutdown). The pair has fast-start failover in zero-data-loss mode (MaxAvailability, threshold 30 s, Shutdown Primary TRUE, Auto-reinstate TRUE, observer on ora-dg-obs, active target cdb19_stby), so the observer is expected to fail over to CDB19_STBY about 30 s after the abort; the scenario waits for CDB19_STBY to report PRIMARY and records when. This is the one scenario that changes the roles of the pair: the revert (lab/oracle/scripts/restore-roles.sh, sourced here, also runnable by hand) brings it back.
# Expectation, derived from packs/oracledb-dg/rules.yml: the sql_query receivers read the role on every collection (15 s), so CDB19_STBY reports oracledb.database.primary 1 after 0 within the last 3 minutes and OraclePrimaryChanged (no hold, cluster level, so the instance part of the key is empty) fires for the cluster cdb19 once the promotion is collected. It covers both promotions: it fires at the failover and resolves 3 minutes later, mid-revert, and fires again when the switchback promotes CDB19 (the reinstated CDB19 reported 0 as a standby, then 1) unless the first one is still active. The reinstate itself (CDB19 mounted, still role PRIMARY, then a standby: 1 then 0) is a demotion and does not fire it; the rule's first version did (three firings in suite oracle-20261118T202631Z-37e22f2); so the record's seconds_to_resolve (from the revert to the first resolved notification after the alert's last firing since detection, lib-core.sh resolution_record) may be the end of the second firing, not of the first, and extra.oracle_primary_changed_notifications lists every notification.
# ALLOW, known consequences of a failed-over pair (not waited for; the run records which were delivered, extra.alerts_seen): OracleProtectionDegraded and OracleFastStartFailoverNotSynchronized for CDB19_STBY (a new primary with no synchronised standby until CDB19 is reinstated; holds 1 m and 2 m), and the same two rules for CDB19 after the switchback until the standby is synchronised again (OracleProtectionDegraded for CDB19 fired once in the fourth trial of 2026-11-15; OracleFastStartFailoverNotSynchronized for CDB19 is allowed because it has the same cause, it was not seen); OracleRedoGap for CDB19_STBY (the new primary's archive destination 2 to the reinstated CDB19 reads RESOLVABLE GAP until CDB19 has fetched the redo it missed while it was down). The CDB19 entries and OracleRedoGap come from failing runs only (trials 1, 3 and 4 of 2026-11-15 failed on these alerts before they were listed, trial 1 also on OracleMultiplePrimaries, which is now gated; the failed rows stay in runs.jsonl); the final trial's row is the evidence. OracleFastStartFailoverObserverMissing for CDB19 (allowed only after a reinstate by command or an archived log restore, decided in revert; the mounted old primary still reports role PRIMARY with fast-start failover enabled and no observer; it fires when the reinstate takes longer than its 2 m hold, as in the runs of 2026-11-16 where flashback needed archived logs restored by restore-roles.sh). OracleBackupStale for CDB19_STBY (the backup queries read the RMAN job history of the database that is primary, packs/oracledb-backup/queries.yaml, and that history is in its own controlfile: once promoted, CDB19_STBY reports the age of the last backup it ran itself while it was primary before; it runs none as a standby, so that age only grows and the alert recurs in every later run while it is over the limit (5 h archived log, 26 h database); first delivered in suite oracle-20261116T173608Z-8b89246, where CDB19_STBY had last been primary from 05:53 to 15:10 UTC that day and its last archived log job was about 5.7 h old at the failover; it has no database job series, so OracleBackupMissing, held 30 m, would fire only if CDB19_STBY stayed primary longer than that, which the revert does not, and it is not allowed). OracleBackupFailed for CDB19_STBY, same cause: when the newest job in its own history failed, it reports that job once promoted (delivered in suite oracle-20261122T125816Z-4f6f8a9: its archived log job of 2026-11-21 04:45 UTC failed with ORA-16456 because a switchover started while it ran, during the live test of the oracledbreceiver role refresh). Not allowed, so each fails the run if delivered: OracleMultiplePrimaries and OracleNoPrimary (both read role PRIMARY together with oracledb.database.open 1, so the mounted old primary that reports role PRIMARY until the observer has reinstated it does not count; the role-only rule fired for it in the trials before the gate), OracleTargetAbsent for CDB19 (the heartbeat of the aborted instance is absent from the abort until the startup mount, extra.heartbeat_cdb19_abort_to_mount; the rule needs 2 minutes of absence plus a 1 minute hold, so it stays quiet as long as the mount comes early enough: the revert mounts at detection + the 30 s hold + about 15 s (about 150 s after the abort in the trials), which leaves a margin of about 30 s against the roughly 180 s the rule needs, so a detection slower than about 130 s would make the run fail on OracleTargetAbsent; assumption), the standby rules for CDB19 after its reinstatement and the lag rules.
# Guard (refuse to start, nothing injected): the shared pre-flight (pair healthy, Alertmanager clean, receivers flowing); CDB19 PRIMARY open read write and CDB19_STBY PHYSICAL STANDBY; the primary's protection level equals its mode with status SYNCHRONIZED; the broker shows Protection Mode MaxAvailability, Fast-Start Failover Enabled in Zero Data Loss Mode, Threshold 30 seconds, Active Target cdb19_stby, Shutdown Primary TRUE and Auto-reinstate TRUE (all asserted, recorded in extra); flashback is on for CDB19 (reinstatement needs it); no rman-backup.sh process on either VM (an unreadable VM refuses too); no managed backup cron job (lab/oracle/scenarios/lib-backup.sh, same schedule on both VMs, the standby's lines would run a backup on a promoted CDB19_STBY) fires from RUN_WINDOW minutes before to BK_NEAR_AFTER minutes after now: like backup-stale the scenario waits for that window to pass instead of failing a whole suite, at most (RUN_WINDOW + BK_NEAR_AFTER + 1) minutes, which covers the whole window, and refuses after that; the safety net unit is not already present. The next due time is recorded.
# Revert (restore_roles in lab/oracle/scripts/restore-roles.sh, from the shared exit trap, so also after a failed inject or Ctrl-C): startup mount of CDB19, wait for the observer to reinstate it as a physical standby and run "reinstate database cdb19" from the new primary when that did not happen within 180 s, "switchover to cdb19" from CDB19_STBY (retried until the broker accepts it), enable fast-start failover again if it is disabled (verified, retried for up to 300 s, the run fails if it stays disabled), then wait until the pair is healthy again (broker SUCCESS, fast-start failover enabled, observer present, apply running, lag at most 10 s), the protection level equals the mode with status SYNCHRONIZED and the active target is cdb19_stby. Every step's epoch is recorded in extra.
# Safety net outside this shell (SIGKILL, out-of-memory kill or a lost session skip the exit trap and would leave CDB19 down and the roles swapped): before the abort the scenario arms a transient user timer, systemd-run --user --unit=obenhub-fsfo-restore --on-active=NET_DELAY, that runs lab/oracle/scripts/restore-roles.sh from the box's user systemd (which takes the lab lock like any run, so it cannot start in the middle of a suite), and stops obenhub-fsfo-restore.timer after a revert that returned 0; a revert that failed leaves it armed. extra.safety_net says whether it was armed and cancelled. Limits: it needs the user systemd manager of this box (Linger=yes for the invoking user is recorded in extra, not changed here) and it does not survive a reboot of the box, which drops the transient timer; a run that is still holding the lock at the deadline makes the net refuse (exit 3) and do nothing.
# Role evidence (the known gap of the oracledbreceiver, record lab/oracle/results/role-staleness-2026-11-13/README.md): extra.role_after_failover and extra.role_after_switchback hold what the sql_query pack (oracledb.database.primary with its role label, read again on every collection) and the oracledb receiver (oracle.db.role and oracle.db.open_mode on its series of CDB19, read once at the Collector's start) report, and the age of the receiver's newest sample. The Collectors are not restarted during the fault. After the switchback the receiver's labels are compared with v$database of CDB19; when they differ, or the receiver emits nothing for 3 minutes, the Collector on ora-dg-obs is restarted (systemctl restart otelcol-contrib, which is what lab/oracle/scripts/collector.sh does on a change) and extra.collector_restarted says so, so that the lab is left as it started.
# shellcheck disable=SC1091,SC2034,SC2016
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-backup.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/restore-roles.sh"

EXPECT=("OraclePrimaryChanged:")
ALLOW=("OracleBackupStale:$STANDBY_SID" "OracleBackupFailed:$STANDBY_SID" "OracleProtectionDegraded:$STANDBY_SID" "OracleProtectionDegraded:$PRIMARY_SID" "OracleFastStartFailoverNotSynchronized:$STANDBY_SID" "OracleFastStartFailoverNotSynchronized:$PRIMARY_SID" "OracleRedoGap:$STANDBY_SID")
DETECT_TIMEOUT=360
DETECT_DEADLINE=360
HOLD_AFTER_DETECT=30
FAILOVER_WAIT=180
# longest run assumed when looking for a backup cron job near the run (minutes); the trial's own duration is in the record
RUN_WINDOW=25
BK_NEAR_BEFORE=$RUN_WINDOW
# wait for the whole window to pass (lib-backup.sh waits 25 minutes, less than the 40 minutes of the window)
BK_WAIT_CLEAR=$(((BK_NEAR_BEFORE + BK_NEAR_AFTER + 1) * 60))
RECEIVER_WAIT=180

ABORT_AT="" ABORT_DONE_AT="" FAILOVER_AT="" FAILOVER_OPEN_AT="" HEALTHY_AT="" SWITCHED_BACK_AT="" VIEW_OK_AT=""
FSFO_BEFORE="" CRON_NEXT="" ROLE_FAILOVER=null ROLE_SWITCHBACK=null ROLE_RESTART=null COLLECTOR_RESTARTED=false COLLECTOR_RESTART_REASON=""
STATE_BEFORE="" STATE_AFTER="" OBS_LINES=null
# safety net: transient user timer that runs restore-roles.sh when this shell cannot
NET_UNIT=obenhub-fsfo-restore
# NET_DELAY must exceed the longest the scenario can hold the lab lock, or the net would fire in the middle of the run,
# find the lock taken, exit 3 and never retry: failover wait + detection deadline + hold + restore_roles bound + the
# waits after it (healthy 600, synchronized 300, sql_query view 120, receiver, restart 180) + resolve + settle + 300 margin
# restore_roles stops starting a restore round at its deadline (RESTORE_TIMEOUT), but a round in flight finishes:
# at most the trace directory query and the log read (2 x REMOTE_TIMEOUT 180) + RMAN (900) + the new mark (trace
# directory query and wc, 2 x 180) + the reinstate (180) = 1800 s past the deadline, so RR_OVERRUN is 1800 and is
# added once below (the 300 s margin alone would not cover it); NET_DELAY comes to 6450 s, about 108 minutes
RR_OVERRUN=1800
NET_DELAY=$((RR_OVERRUN + FAILOVER_WAIT + DETECT_DEADLINE + HOLD_AFTER_DETECT + RESTORE_TIMEOUT + 600 + 300 + 120 + RECEIVER_WAIT + 180 + RESOLVE_TIMEOUT + SETTLE_TIMEOUT + 300))
RESTART_AT=""
NET_ARMED=false NET_CANCELLED=false NET_ARMED_AT="" NET_NOTE="" LINGER=""

# minutes until the next managed backup cron time (the list of cron_near, same on both VMs)
next_backup_due() {
  local t f d best=99999 m; t=$(host_minute_of_day) || return 1
  for f in 45 105 285 525 765 1005 1245; do
    for d in 0 1440; do m=$((f + d - t)); [ "$m" -ge 0 ] && [ "$m" -lt "$best" ] && best=$m; done
  done
  echo "$best"
}
# rman_running HOST: an rman-backup.sh or rman process runs there
# status 0 running, 1 not running, anything else (ssh 255, timeout 124) unreadable: the guard refuses on both 0 and unreadable
# (the exit status of pgrep is read on the VM, so that a failing sudo, which also exits 1, is not "not running")
rman_running() {
  local out rcl
  out=$(rn "$1" sh -c 'pgrep -f "$1" >/dev/null; echo "rc=$?"' _ '[r]man-backup.sh') || return 2
  rcl=$(grep '^rc=' <<<"$out" | tail -n 1)
  case $rcl in rc=0) return 0 ;; rc=1) return 1 ;; *) return 2 ;; esac
}

# fsfo_summary: protection mode, fast-start failover state, threshold, active target, Shutdown Primary and Auto-reinstate of the broker, one line
fsfo_summary() {
  { dg_up 'show configuration' | sed -n 's/^ *\(Protection Mode\): *\(.*[^ ]\) *$/\1=\2/p'
    dg_up 'show fast_start failover' | sed -n -e 's/^\(Fast-Start Failover\): *\(.*[^ ]\) *$/\1=\2/p' -e 's/^ *\(Threshold\|Active Target\|Shutdown Primary\|Auto-reinstate\): *\(.*[^ ]\) *$/\1=\2/p'
  } | tr '\n' ';'
}

# safety net: arm (before the abort) and cancel (after a revert that returned 0)
arm_net() {
  LINGER=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null) || LINGER=unknown
  local out
  out=$(systemd-run --user --unit="$NET_UNIT" --description="obenhub fsfo-failover safety net: restore-roles.sh" --on-active="$NET_DELAY" "$LAB_DIR/scripts/restore-roles.sh" 2>&1) || { NET_NOTE="systemd-run failed: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  NET_ARMED=true; NET_ARMED_AT=$(date +%s)
}
# a transient unit that fired and failed stays loaded (failed) until reset-failed
unit_loaded() { [ "$(systemctl --user show -p LoadState --value "$1" 2>/dev/null)" = loaded ]; }
net_present() { unit_loaded "$NET_UNIT.timer" || unit_loaded "$NET_UNIT.service"; }
cancel_net() {
  [ "$NET_ARMED" = true ] || return 0
  systemctl --user stop "$NET_UNIT.timer" "$NET_UNIT.service" 2>/dev/null
  systemctl --user reset-failed "$NET_UNIT.timer" "$NET_UNIT.service" 2>/dev/null
  if net_present; then NET_NOTE="the safety net unit is still loaded after stop and reset-failed"; return 1; fi
  NET_CANCELLED=true
}

# role_view: what the sql_query pack and the oracledb receiver report now, as JSON
role_view() {
  local now s r
  now=$(date +%s)
  s=$(curl -fsS "$VM/api/v1/query" --data-urlencode 'query=last_over_time(oracledb.database.primary[1m])' \
    | jq -c '[.data.result[] | {id: .metric["service.instance.id"], role: .metric["oracledb.database.role"], primary: (.value[1] | tonumber)}] | sort_by(.id, .role)') || s=null
  r=$(curl -fsS "$VM/api/v1/query" --data-urlencode 'query=tlast_over_time(oracledb.processes.usage[10m])' \
    | jq -c --argjson now "$now" '[.data.result[] | {id: .metric["service.instance.id"], role: .metric["oracle.db.role"], open_mode: .metric["oracle.db.open_mode"], newest_sample_age_s: ($now - (.value[1] | tonumber) | floor)}]') || r=null
  jq -n -c --argjson s "${s:-null}" --argjson r "${r:-null}" '{sql_query_primary_flag: $s, oracledb_receiver_series: $r}'
}
# receiver_fresh [SINCE]: the receiver's newest sample of CDB19 is younger than 45 s and, when SINCE (epoch) is given, newer than SINCE
receiver_fresh() {
  local t
  # max(): after a Collector restart the old and the new label set are both in the window
  t=$(vm_query "max(tlast_over_time(oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}[10m]))") || return 1
  [ -n "$t" ] && [ "${t%.*}" -gt "${1:-0}" ] && [ "$(($(date +%s) - ${t%.*}))" -lt 45 ]
}
# receiver_role: oracle.db.role and oracle.db.open_mode of the receiver's newest series of CDB19, "ROLE|MODE"
receiver_role() {
  curl -fsS "$VM/api/v1/query" --data-urlencode "query=tlast_over_time(oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}[3m])" \
    | jq -r '[.data.result[]] | sort_by(.value[1] | tonumber) | (last // {}) | (.metric // {}) | (.["oracle.db.role"] // "none") + "|" + (.["oracle.db.open_mode"] // "none")'
}
# switchback_view_ok: the sql_query flags show exactly CDB19 primary 1 and CDB19_STBY standby 0 in the last 30 s
switchback_view_ok() {
  [ "$(curl -fsS "$VM/api/v1/query" --data-urlencode 'query=last_over_time(oracledb.database.primary[30s])' \
    | jq -r '[.data.result[] | .metric["service.instance.id"] + ":" + .metric["oracledb.database.role"] + ":" + .value[1]] | sort | join(",")')" = "CDB19:PRIMARY:1,CDB19_STBY:PHYSICAL STANDBY:0" ]
}
# target_ok: the broker's active target is cdb19_stby and the primary is synchronized
target_ok() { dg "$PRIMARY_SID" 'show fast_start failover' | grep '^ *Active Target: *cdb19_stby' >/dev/null && sync_ok; }

# pre-flight on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local h rc
  # first, so that every state read below is from the moment of the abort, not up to the window earlier
  wait_cron_clear || { PRE_ERR=${PRE_ERR:-"a managed backup cron job fires within ${BK_NEAR_BEFORE} minutes before to ${BK_NEAR_AFTER} after now (VM clock) after ${BK_WAIT_CLEAR}s of waiting"}; return 1; }
  wait_until "$SETTLE_TIMEOUT" "only Watchdog active in Alertmanager" am_clean || { PRE_ERR="Alertmanager not clean after the backup window: $(am_active | tr '\n' ' ')"; return 1; }
  base_pre || return 1
  STATE_BEFORE="$(inst_state "$PRIMARY_SID") / $(inst_state "$STANDBY_SID")"
  [ "$STATE_BEFORE" = 'OPEN|PRIMARY|READ WRITE / MOUNTED|PHYSICAL STANDBY|MOUNTED' ] || { PRE_ERR="roles are not the lab's (CDB19 / CDB19_STBY: $STATE_BEFORE); lab/oracle/scripts/restore-roles.sh"; return 1; }
  sync_ok || { PRE_ERR="the primary is not SYNCHRONIZED at its protection level"; return 1; }
  FSFO_BEFORE=$(fsfo_summary)
  for h in 'Protection Mode=MaxAvailability' 'Fast-Start Failover=Enabled in Zero Data Loss Mode' 'Threshold=30 seconds' 'Active Target=cdb19_stby' 'Shutdown Primary=TRUE' 'Auto-reinstate=TRUE'; do
    grep -qF "$h;" <<<"$FSFO_BEFORE" || { PRE_ERR="broker fast-start failover settings lack '$h' (read: $FSFO_BEFORE)"; return 1; }
  done
  [ "$(ora_sql "$PRIMARY_SID" <<<'SELECT flashback_on FROM v$database;')" = YES ] || { PRE_ERR="flashback is not on for $PRIMARY_SID (reinstatement needs it)"; return 1; }
  for h in "$PRIMARY_HOST" "$STANDBY_HOST"; do
    rman_running "$h"; rc=$?
    [ "$rc" = 1 ] || { PRE_ERR="an rman-backup.sh process runs on $h (or the host cannot be read: status $rc)"; return 1; }
  done
  ! net_present || { PRE_ERR="the safety net unit $NET_UNIT is already present (systemctl --user stop $NET_UNIT.timer $NET_UNIT.service; systemctl --user reset-failed $NET_UNIT.timer $NET_UNIT.service)"; return 1; }
  CRON_NEXT=$(next_backup_due) || { PRE_ERR="cannot read the clock of $PRIMARY_HOST"; return 1; }
  log "guard ok: $STATE_BEFORE; $FSFO_BEFORE next managed backup cron time in $CRON_NEXT min"
}

inject() {
  local r t0
  arm_net || { FAILS+=("safety net not armed: $NET_NOTE"); return 1; }
  ABORT_AT=$(date +%s)
  ora_sql "$PRIMARY_SID" <<<'shutdown abort' >/dev/null || { FAILS+=("shutdown abort on $PRIMARY_SID failed"); return 1; }
  ABORT_DONE_AT=$(date +%s)
  log "$PRIMARY_SID aborted in $((ABORT_DONE_AT - ABORT_AT)) s; waiting for the failover (at most ${FAILOVER_WAIT}s)"
  t0=$ABORT_AT
  while [ $(($(date +%s) - t0)) -lt "$FAILOVER_WAIT" ]; do
    r=$(ora_sql "$STANDBY_SID" <<<"SELECT database_role || '|' || open_mode FROM v\$database;" 2>/dev/null) || r=""
    case $r in
      'PRIMARY|MOUNTED') [ -n "$FAILOVER_AT" ] || FAILOVER_AT=$(date +%s) ;;
      'PRIMARY|READ WRITE') [ -n "$FAILOVER_AT" ] || FAILOVER_AT=$(date +%s); FAILOVER_OPEN_AT=$(date +%s); break ;;
    esac
    sleep 2
  done
  [ -n "$FAILOVER_OPEN_AT" ] || { FAILS+=("$STANDBY_SID is not PRIMARY and open ${FAILOVER_WAIT}s after the abort (last read: '${r:-none}')"); return 1; }
  log "$STANDBY_SID PRIMARY: role at +$((FAILOVER_AT - ABORT_AT)) s, open at +$((FAILOVER_OPEN_AT - ABORT_AT)) s"
}

after_detect() {
  ROLE_FAILOVER=$(role_view) || ROLE_FAILOVER=null
  log "role view after the failover: $ROLE_FAILOVER"
}

revert() {
  local rc=0 st
  # nothing was aborted (the inject failed before): nothing to restore
  [ -n "$ABORT_AT" ] || { cancel_net; return 0; }
  restore_roles
  rc=$?
  SWITCHED_BACK_AT=$RR_RESTORED_AT
  # the mounted old primary reports role PRIMARY with fast-start failover enabled and no observer until it is
  # reinstated; the rule (2 m hold) fires only when the observer did not do that quickly. Allowed only when
  # restore_roles had to reinstate by command or restore archived logs; after an automatic reinstate it stays unexpected.
  if [ "$RR_REINSTATE_MANUAL" = yes ] || [ "${RR_ARCH_RESTORE_ROUNDS:-0}" -gt 0 ]; then ALLOW+=("OracleFastStartFailoverObserverMissing:$PRIMARY_SID"); fi
  if [ "$rc" -ne 0 ]; then
    FAILS+=("restore_roles: ${RR_LAST_ERR:-failed} (status $rc); run lab/oracle/scripts/restore-roles.sh")
    return 1
  fi
  wait_until 600 "pair healthy after the switchback" healthy_pair || { FAILS+=("pair not healthy 600 s after the roles were restored"); rc=1; }
  HEALTHY_AT=$(date +%s)
  wait_until 300 "synchronized with target cdb19_stby" target_ok || { FAILS+=("fast-start failover not SYNCHRONIZED with target cdb19_stby 300 s after the restore"); rc=1; }
  STATE_AFTER="$(inst_state "$PRIMARY_SID") / $(inst_state "$STANDBY_SID")"
  [ "$STATE_AFTER" = "$STATE_BEFORE" ] || { FAILS+=("instance states after the revert differ from before: $STATE_AFTER vs $STATE_BEFORE"); rc=1; }
  # roles as the collectors report them, once the old role series have aged out of the window
  wait_until 120 "sql_query flags show CDB19 primary and CDB19_STBY standby" switchback_view_ok && VIEW_OK_AT=$(date +%s)
  wait_until "$RECEIVER_WAIT" "oracledb receiver emitting for $PRIMARY_SID" receiver_fresh
  ROLE_SWITCHBACK=$(role_view) || ROLE_SWITCHBACK=null
  log "role view after the switchback: $ROLE_SWITCHBACK"
  st=$(receiver_role) || st=""
  if [ "$st" != 'PRIMARY|READ WRITE' ]; then
    COLLECTOR_RESTART_REASON="receiver labels '${st:-none}' for CDB19, the database is PRIMARY|READ WRITE (or the receiver emits nothing)"
  elif ! receiver_fresh; then
    COLLECTOR_RESTART_REASON="receiver not emitting for CDB19 ${RECEIVER_WAIT}s after the switchback"
  fi
  if [ -n "$COLLECTOR_RESTART_REASON" ]; then
    log "restarting otelcol-contrib on $OBSERVER_HOST: $COLLECTOR_RESTART_REASON"
    retry rn "$OBSERVER_HOST" systemctl restart otelcol-contrib || { FAILS+=("otelcol-contrib restart on $OBSERVER_HOST failed three times"); rc=1; }
    COLLECTOR_RESTARTED=true
    RESTART_AT=$(date +%s)
    wait_until 180 "oracledb receiver emitting after the restart" receiver_fresh "$RESTART_AT" || { FAILS+=("receiver not emitting for $PRIMARY_SID 180 s after the Collector restart"); rc=1; }
    ROLE_RESTART=$(role_view) || ROLE_RESTART=null
  fi
  # the observer's own account of the failover and the reinstatement (root on the observer VM reads the log)
  OBS_LINES=$(rn "$OBSERVER_HOST" grep -E -i 'failover|reinstat|fsfo|lost|connected' /u01/app/oracle/dg/cdb19/observer.log 2>/dev/null | tail -n 14 | cut -c1-220 | jq -R . | jq -s -c .) || OBS_LINES=null
  if [ "$rc" = 0 ]; then
    cancel_net || { FAILS+=("safety net not cancelled: $NET_NOTE"); rc=1; }
  else
    log "revert failed: the safety net $NET_UNIT stays armed (restore-roles.sh at +${NET_DELAY}s)"
  fi
  return "$rc"
}

extra_checks() {
  local a=$ABORT_AT b=${RR_MOUNT_AT:-$ABORT_AT} seen hbp hbs notes err base
  [ -n "$a" ] || return 0
  hbp=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hbp=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "${HEALTHY_AT:-$b}" 15) || hbs=null
  seen=$(window_alerts "$T_START" "$T_END" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {alertname: .[0], instance: .[1], status: .[2], count: (.[3] | tonumber)})') || seen=null
  notes=$(vl "_time:>$T_START status:* commonLabels.alertname:=OraclePrimaryChanged | sort by (_time) | fields _time, status" | jq -c '[._time, .status]' | jq -s -c .) || notes=null
  err=$(collector_errors "$a" "${HEALTHY_AT:-$(date +%s)}") || err=null
  base=$(jq -n -c --argjson a "${a:-null}" --arg fover "${FAILOVER_AT:-}" --arg fopen "${FAILOVER_OPEN_AT:-}" --arg ret "${ABORT_DONE_AT:-}" \
    --arg mount "${RR_MOUNT_AT:-}" --arg rseen "${RR_REINSTATE_SEEN_AT:-}" --arg rcmd "${RR_REINSTATE_CMD_AT:-}" --arg sby "${RR_STANDBY_AT:-}" \
    --arg sw "${RR_SWITCH_CMD_AT:-}" --arg back "${SWITCHED_BACK_AT:-}" --arg ok "${HEALTHY_AT:-}" --arg vok "${VIEW_OK_AT:-}" \
    'def n: if . == "" then null else tonumber end;
     {abort_epoch: $a, abort_returned_epoch: ($ret | n), failover_role_epoch: ($fover | n), failover_open_epoch: ($fopen | n),
      abort_to_failover_s: (if $fover == "" then null else ($fover | tonumber) - $a end),
      abort_to_open_s: (if $fopen == "" then null else ($fopen | tonumber) - $a end),
      mount_epoch: ($mount | n), reinstate_seen_epoch: ($rseen | n), reinstate_command_epoch: ($rcmd | n), cdb19_standby_seen_epoch: ($sby | n),
      switchover_command_epoch: ($sw | n), roles_restored_epoch: ($back | n), healthy_epoch: ($ok | n), sql_query_view_restored_epoch: ($vok | n)}')
  EXTRA_JSON=$(jq -n -c --argjson base "$base" --argjson hbp "${hbp:-null}" --argjson hbs "${hbs:-null}" --argjson seen "${seen:-null}" --argjson notes "${notes:-null}" \
    --argjson err "${err:-null}" --argjson rf "${ROLE_FAILOVER:-null}" --argjson rs "${ROLE_SWITCHBACK:-null}" --argjson rr "${ROLE_RESTART:-null}" --argjson obs "${OBS_LINES:-null}" \
    --arg fsfo "$FSFO_BEFORE" --arg sb "$STATE_BEFORE" --arg sa "$STATE_AFTER" --arg cron "$CRON_NEXT" \
    --argjson armed "$NET_ARMED" --argjson cancelled "$NET_CANCELLED" --arg narmed "$NET_ARMED_AT" --arg nnote "$NET_NOTE" --arg linger "$LINGER" --argjson ndelay "$NET_DELAY" \
    --argjson restarted "$COLLECTOR_RESTARTED" --arg reason "$COLLECTOR_RESTART_REASON" --arg manual "$RR_REINSTATE_MANUAL" --argjson arounds "${RR_ARCH_RESTORE_ROUNDS:-0}" --argjson afailed "${RR_ARCH_RESTORE_FAILED:-0}" --arg aseqs "${RR_ARCH_RESTORE_SEQS:-}" \
    '$base + {reinstated_by_command: ($manual == "yes"), archivelog_restore_rounds: $arounds, archivelog_restore_failed: $afailed, archivelog_restore_from: ($aseqs | split(" ") | map(select(length > 0))), fsfo_settings_before: $fsfo, instance_states_before: $sb, instance_states_after: $sa,
      next_backup_cron_in_min_at_start: ($cron | tonumber? // null),
      heartbeat_cdb19_abort_to_mount: $hbp, heartbeat_cdb19_stby_abort_to_healthy: $hbs,
      alerts_seen: $seen, oracle_primary_changed_notifications: $notes, collector_log: $err,
      role_after_failover: $rf, role_after_switchback: $rs, collector_restarted: $restarted, collector_restart_reason: $reason, role_after_collector_restart: $rr,
      observer_log_tail: $obs,
      safety_net: {unit: "obenhub-fsfo-restore", delay_s: $ndelay, armed: $armed, armed_epoch: ($narmed | tonumber? // null), cancelled: $cancelled, note: $nnote, linger: $linger}}')
  log "extra: $EXTRA_JSON"
}
run_scenario fsfo-failover
