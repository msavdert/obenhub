#!/usr/bin/env bash
# Scenario listener-stopped: the Oracle Net listener on the primary VM ora-au-lab is stopped (lsnrctl stop as the oracle OS user) and started again after the alert was seen. That listener (LISTENER, run from the 26ai home, listener.ora with static entries for the 19c databases) serves every database on the VM: CDB19, and also CDB19B (the primary of a second pair with its own fast-start failover configuration and observer) and CDB26, whose new connections fail while it is down. So the stop also hits the FSFO pair CDB19B: the scenario refuses to start unless CDB19B is SYNCHRONIZED with a SUCCESS configuration, guards it exactly like CDB19 during the outage and records its states. Sessions that exist keep working, so the instances, redo transport and the brokers (bequeath connections, existing transport sessions) are expected to carry on; the guard checks that, it is not assumed.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml: the tcp_check/primary receiver on ora-dg-obs records tcpcheck.status 0 for ora-au-lab.lab.local:1521 on every 15 s collection, so OracleListenerUnreachable (last_over_time(...[30s]) == 0, hold 1m) fires for CDB19. Measured in the trial of 2026-11-14T17:57:45Z: first 0 sample +5.7 s, pending +13 s, firing at +73 s, delivered at +115 s; startsAt-to-delivery 42 s for every alert on the stack, cause not yet found. No other alert is expected. OracleTargetAbsent needs the heartbeat of CDB19 absent for 2m plus a 1m hold, which is longer than the bounded outage here; every other rule reads series that the sql_query and oracledb receivers keep producing if their pooled sessions survive. Any other alert is reported as unexpected. The standby listener is not touched.
# Guard: both pairs have fast-start failover with Shutdown Primary TRUE (a failover aborts the old primary). A background check every 10 s reads role, open mode, fs_failover_status and observer presence of CDB19 and CDB19B (bequeath, no listener needed) and, every third round, both broker configurations. If a primary is not PRIMARY and open read write, if a configuration no longer lists it as primary, or if two consecutive reads of a database fail (an aborted primary cannot be read), the listener is started at once and the run fails; nothing else is changed. The outage is bounded: detection is cut off 200 s after the stop (DETECT_DEADLINE), the fault is held 45 s after the alert, and revert always starts the listener (also on Ctrl-C, through the shared exit trap). The guard finishes the step it is in before it exits and revert waits for it, so a start is never cut in half.
# The listener is started with the TNS_ADMIN of the running one, read from /proc/PID/environ; both trials of 2026-11-14 read it from a listener that the scenario or a manual repair had started, not from one started by oracle-db.service (start_all.sh exports TNS_ADMIN, so it is expected to work).
# Evidence for ADR 0008 decision 7 (does a pooled session keep the database metrics flowing with the listener stopped): the record's extra field holds, for the window between the end of the stop and the start of the start, the samples of the oracledb receiver's series (C##OBENHUB_MON), of the sql_query heartbeat of both databases (C##OBENHUB_DG as SYSDG) and of tcpcheck.status from VictoriaMetrics, the error codes the Collector logged (journald on ora-dg-obs; codes and counts only, no log text) and the FSFO state of CDB19 and CDB19B before, during and after.
# Revert: stop the guard (wait for it), start the listener unless it runs (three attempts), alter system register on CDB19, wait until the listener services equal those listed before the stop, the probe reads 1 and the pair is healthy.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleListenerUnreachable:$PRIMARY_SID")
ALLOW=()
DETECT_DEADLINE=200
HOLD_AFTER_DETECT=45

# CDB19B (second pair) is a primary on the same VM as CDB19; lib.sh knows only
# the CDB19 pair, so teach sid_host about it for ora_sql and dg
B_SID=CDB19B
sid_host() { case "$1" in "$PRIMARY_SID" | "$B_SID") echo "$PRIMARY_HOST" ;; "$STANDBY_SID") echo "$STANDBY_HOST" ;; *) return 1 ;; esac; }

LSNR_HOME="" LSNR_NAME="" LSNR_TNS="" FIND_ERR=""
STOP_AT="" START_AT=""
SERVICES_BEFORE=""
FSFO_BEFORE="" FSFO_AFTER="" FSFO_DURING="" B_BEFORE="" B_AFTER="" B_DURING="" GUARD_ABORT=""
GUARD_PID=""
GUARD_DIR=""

# lsnr_find: home, name and TNS_ADMIN of the running listener on the primary
# VM, from its process; sets FIND_ERR on failure
lsnr_find() {
  local line pid
  line=$(rn "$PRIMARY_HOST" pgrep -a -u oracle -x tnslsnr | head -n1)
  [ -n "$line" ] || { FIND_ERR="no running tnslsnr process on $PRIMARY_HOST"; return 1; }
  pid=${line%% *}
  LSNR_HOME=$(awk '{print $2}' <<<"$line" | sed 's#/bin/tnslsnr$##')
  LSNR_NAME=$(awk '{print $3}' <<<"$line")
  [[ $LSNR_HOME =~ ^/[A-Za-z0-9_/.-]+$ && $LSNR_NAME =~ ^[A-Za-z0-9_]+$ ]] || { FIND_ERR="cannot parse the listener home or name from: $line"; return 1; }
  # without TNS_ADMIN a started listener reads no listener.ora (no static
  # *_DGMGRL services, no IPC endpoint); found by the trial of 2026-11-14 17:50Z
  LSNR_TNS=$(rn "$PRIMARY_HOST" cat "/proc/$pid/environ" | tr '\0' '\n' | sed -n 's/^TNS_ADMIN=//p')
  [[ $LSNR_TNS =~ ^/[A-Za-z0-9_/.-]+$ ]] || { FIND_ERR="the running listener has no TNS_ADMIN in its environment (a restart would not read listener.ora)"; return 1; }
}
lsnr_running() { rn "$PRIMARY_HOST" pgrep -u oracle -x tnslsnr >/dev/null; }
# lsnr CMD: lsnrctl CMD on the listener as oracle
lsnr() { timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo -u oracle env ORACLE_HOME=$LSNR_HOME TNS_ADMIN=$LSNR_TNS $LSNR_HOME/bin/lsnrctl $1 $LSNR_NAME"; }
# lsnr_start: the listener daemon must not hold the ssh pipe open, so lsnrctl
# writes to a file
lsnr_start() {
  timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo -u oracle env ORACLE_HOME=$LSNR_HOME TNS_ADMIN=$LSNR_TNS bash -c '$LSNR_HOME/bin/lsnrctl start $LSNR_NAME </dev/null >/tmp/obenhub-lsnr-start.out 2>&1; rc=\$?; tail -n 2 /tmp/obenhub-lsnr-start.out; exit \$rc'"
}
# services: the Service and Instance lines of lsnrctl status, in order
services() { lsnr status | grep -E '^(Service|  Instance)'; }
services_back() { [ "$(services)" = "$SERVICES_BEFORE" ]; }
probe_up() { [ "$(vm_query "last_over_time(tcpcheck.status{service.instance.id=\"$PRIMARY_SID\"}[30s])")" = 1 ]; }
# fsfo_state SID: ROLE|OPEN_MODE|FS_FAILOVER_STATUS|OBSERVER_PRESENT
fsfo_state() { ora_sql "$1" <<<"SELECT database_role || '|' || open_mode || '|' || fs_failover_status || '|' || fs_failover_observer_present FROM v\$database;"; }
# broker_ok SID LOWERCASE_NAME: configuration SUCCESS, fast-start failover
# enabled, the database listed as primary
broker_ok() {
  local c; c=$(dg "$1" 'show configuration') || return 1
  grep -q '^SUCCESS' <<<"$c" && grep -q 'Fast-Start Failover: Enabled' <<<"$c" && grep -qi "^ *$2 *- Primary" <<<"$c"
}

# guard_loop: runs in the background from the injection until revert. TERM
# only sets a flag: the step in progress (a read, a listener start) finishes,
# then the loop ends. Shorter remote timeouts than the scenario's.
guard_loop() {
  local stop=0 n=0 sp="" sid tag st cfg cfgsid cfgname bad_a=0 bad_b=0
  trap 'stop=1; [ -z "$sp" ] || kill "$sp" 2>/dev/null' TERM
  while [ "$stop" = 0 ]; do
    sleep 10 & sp=$!
    wait "$sp"
    sp=""
    [ "$stop" = 0 ] || break
    n=$((n + 1))
    for sid in "$PRIMARY_SID" "$B_SID"; do
      tag=A; [ "$sid" = "$B_SID" ] && tag=B
      if st=$(REMOTE_TIMEOUT=30 fsfo_state "$sid" 2>/dev/null) && [ -n "$st" ]; then
        echo "$(date +%s) $tag $st" >>"$GUARD_LOG"
        [ "$tag" = A ] && bad_a=0 || bad_b=0
        case $st in
          'PRIMARY|READ WRITE|'*) ;;
          *) echo "$sid state changed: $st" >>"$GUARD_FLAG" ;;
        esac
      else
        echo "$(date +%s) $tag unreadable" >>"$GUARD_LOG"
        if [ "$tag" = A ]; then bad_a=$((bad_a + 1)); [ "$bad_a" -lt 2 ] || echo "$sid unreadable twice in a row" >>"$GUARD_FLAG"
        else bad_b=$((bad_b + 1)); [ "$bad_b" -lt 2 ] || echo "$sid unreadable twice in a row" >>"$GUARD_FLAG"; fi
      fi
    done
    if [ ! -e "$GUARD_FLAG" ] && [ $((n % 3)) -eq 0 ]; then
      for cfgsid in "$PRIMARY_SID" "$B_SID"; do
        cfgname=${cfgsid,,}
        cfg=$(REMOTE_TIMEOUT=45 dg "$cfgsid" 'show configuration' 2>/dev/null) || continue
        grep -qi "^ *$cfgname *- Primary" <<<"$cfg" || echo "broker no longer lists $cfgname as primary" >>"$GUARD_FLAG"
      done
    fi
    if [ -e "$GUARD_FLAG" ]; then
      echo "$(date +%s) abort: $(tr '\n' ';' <"$GUARD_FLAG"); starting the listener" >>"$GUARD_LOG"
      lsnr_start >>"$GUARD_LOG" 2>&1
      return 0
    fi
  done
}
# guard_collect: stop the guard and wait until it has exited, read what it
# saw, remove its directory; safe to call more than once
guard_collect() {
  if [ -n "$GUARD_PID" ]; then
    kill -TERM "$GUARD_PID" 2>/dev/null
    wait "$GUARD_PID" 2>/dev/null
    GUARD_PID=""
  fi
  [ -n "$GUARD_DIR" ] || return 0
  summarize() { grep " $1 " "$GUARD_LOG" 2>/dev/null | cut -d' ' -f3- | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }
  FSFO_DURING=$(summarize A)
  B_DURING=$(summarize B)
  [ ! -e "$GUARD_FLAG" ] || GUARD_ABORT=$(tr '\n' ';' <"$GUARD_FLAG")
  rm -rf "${GUARD_DIR:?}"
  GUARD_DIR=""
}

# pre-flight of this scenario on top of the adapter's: the listener, the
# services it lists and both pairs must be in the state revert restores (before
# the injection, so that the time to detect starts at the stop)
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  base_pre || return 1
  lsnr_find || { PRE_ERR="$FIND_ERR"; return 1; }
  log "listener $LSNR_NAME from $LSNR_HOME, TNS_ADMIN $LSNR_TNS"
  SERVICES_BEFORE=$(services) && [ -n "$SERVICES_BEFORE" ] || { SERVICES_BEFORE=""; PRE_ERR="cannot read the listener services before the stop"; return 1; }
  grep -q 'Instance "CDB19", status READY' <<<"$SERVICES_BEFORE" || { PRE_ERR="CDB19 is not registered READY at the listener before the stop"; return 1; }
  FSFO_BEFORE=$(fsfo_state "$PRIMARY_SID") || { PRE_ERR="cannot read the CDB19 state before the stop"; return 1; }
  [ "$FSFO_BEFORE" = 'PRIMARY|READ WRITE|SYNCHRONIZED|YES' ] || { PRE_ERR="CDB19 is not PRIMARY, READ WRITE, SYNCHRONIZED with an observer before the stop: $FSFO_BEFORE"; return 1; }
  B_BEFORE=$(fsfo_state "$B_SID") || { PRE_ERR="cannot read the CDB19B state before the stop"; return 1; }
  [ "$B_BEFORE" = 'PRIMARY|READ WRITE|SYNCHRONIZED|YES' ] || { PRE_ERR="CDB19B is not PRIMARY, READ WRITE, SYNCHRONIZED with an observer before the stop (the listener is shared): $B_BEFORE"; return 1; }
  broker_ok "$B_SID" cdb19b || { PRE_ERR="the CDB19B broker configuration is not SUCCESS with fast-start failover enabled and cdb19b primary"; return 1; }
  log "state before: CDB19 $FSFO_BEFORE, CDB19B $B_BEFORE"
}

inject() {
  GUARD_DIR=$(mktemp -d)
  GUARD_FLAG="$GUARD_DIR/abort"
  GUARD_LOG="$GUARD_DIR/states"
  guard_loop &
  GUARD_PID=$!
  lsnr stop >/dev/null || { FAILS+=("lsnrctl stop failed"); return 1; }
  STOP_AT=$(date +%s)
  ! lsnr_running || { FAILS+=("listener process still running after lsnrctl stop"); return 1; }
  log "listener stopped"
}
revert() {
  local rc=0
  guard_collect
  # nothing was stopped (inject refused or failed before the stop): nothing to restore
  if [ -z "$STOP_AT" ] && { [ -z "$LSNR_HOME" ] || lsnr_running; }; then return 0; fi
  # the guard may have started the listener; decide only now that it has exited
  if ! lsnr_running; then
    START_AT=$(date +%s)
    retry lsnr_start >/dev/null || { FAILS+=("lsnrctl start failed three times: the listener on $PRIMARY_HOST may be left stopped"); return 1; }
    log "listener started"
  fi
  [ -n "$START_AT" ] || START_AT=$(date +%s)
  # the instance registers on its own within about 60 s (LREG); do not wait for it
  ora_sql "$PRIMARY_SID" <<<'ALTER SYSTEM REGISTER;' >/dev/null || log "alter system register failed (the wait below decides)"
  if [ -n "$SERVICES_BEFORE" ]; then
    wait_until 180 "listener services as before the stop" services_back || { FAILS+=("listener services differ from the state before the stop"); rc=1; }
  fi
  wait_until 120 "tcpcheck.status 1 for $PRIMARY_SID" probe_up || { FAILS+=("probe still not 1 two minutes after the start"); rc=1; }
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the start"); rc=1; }
  FSFO_AFTER=$(fsfo_state "$PRIMARY_SID") || FSFO_AFTER="unreadable"
  B_AFTER=$(fsfo_state "$B_SID") || B_AFTER="unreadable"
  [ "$B_AFTER" = 'PRIMARY|READ WRITE|SYNCHRONIZED|YES' ] || { FAILS+=("CDB19B after the start: $B_AFTER"); rc=1; }
  [ -z "$GUARD_ABORT" ] || { FAILS+=("guard aborted the run: $GUARD_ABORT"); rc=1; }
  return "$rc"
}

extra_checks() {
  local a=$STOP_AT b=$START_AT sess proc cpu hb hbs tc err
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the oracledb receiver (C##OBENHUB_MON, 30 s)
  sess=$(series_stats "oracledb.sessions.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || sess=null
  proc=$(series_stats "oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || proc=null
  cpu=$(series_stats "oracledb.cpu_time{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || cpu=null
  # the sql_query heartbeat (C##OBENHUB_DG as SYSDG, 15 s); the standby is the control
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "$b" 15) || hbs=null
  tc=$(series_stats "tcpcheck.status{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || tc=null
  err=$(collector_errors "$a" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson a "$a" --argjson b "$b" --argjson sess "${sess:-null}" --argjson proc "${proc:-null}" --argjson cpu "${cpu:-null}" \
    --argjson hb "${hb:-null}" --argjson hbs "${hbs:-null}" --argjson tc "${tc:-null}" --argjson err "${err:-null}" \
    --arg before "$FSFO_BEFORE" --arg during "$FSFO_DURING" --arg after "$FSFO_AFTER" \
    --arg pre_b "$B_BEFORE" --arg mid_b "$B_DURING" --arg post_b "$B_AFTER" \
    '{stop_epoch: $a, start_epoch: $b, listener_stopped_s: ($b - $a),
      oracledb_receiver: {sessions_usage: $sess, processes_usage: $proc, cpu_time: $cpu},
      heartbeat_primary: $hb, heartbeat_standby: $hbs, tcpcheck_primary: $tc, collector_log: $err,
      fsfo_before: $before, fsfo_during: $during, fsfo_after: $after,
      cdb19b_before: $pre_b, cdb19b_during: $mid_b, cdb19b_after: $post_b}')
  log "extra: $EXTRA_JSON"
}
run_scenario listener-stopped
