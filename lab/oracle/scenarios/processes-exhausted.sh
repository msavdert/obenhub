#!/usr/bin/env bash
# Scenario processes-exhausted: the CDB19 primary on ora-au-lab runs out of process slots (PROCESSES = 320). Holder sessions are started until a fresh login fails: each is a local bequeath `sqlplus -s / as sysdba` as the oracle OS user (operating-system authentication, no password) that runs `exec dbms_session.sleep(HOLD_CAP)` and exits, so it occupies one dedicated server process and ends by itself after HOLD_CAP seconds even if this script dies. All holders, their server processes included (a bequeath server process is a child of its client), live in one transient systemd unit on ora-au-lab (UNIT, limits: MemoryMax, TasksMax, a low CPUWeight), so the revert is one `systemctl stop` of that unit. The database is not restarted and no parameter is changed.
# Expectation, derived from packs/oracledb-dg/rules.yml: the oracledb receiver (C##OBENHUB_MON, a pooled session, 30 s) keeps reporting oracledb.processes.usage and .limit, the ratio reaches 1 and OracleProcessesSaturation fires for CDB19 as critical. EXPECT matches alertname and instance, not severity, so both tiers are covered by the one entry; the critical tier is asserted in after_detect (severity_seen). The ramp crosses the warning band (0.85 to 0.95, 32 of 320 slots) in a few seconds, shorter than the 90 s window, so the warning tier is not expected to be delivered (it can be for one evaluation when a scrape lands inside the band); a warning delivery is no failure (after_detect waits up to 120 s for the critical one), a missing critical one is. ALLOW stays empty because the warning shares the name. Nothing else is expected, and any other alert is reported as unexpected.
# Guard: besides the shared pre-flight (pair healthy, receivers flowing) the run refuses to start unless CDB19 is the PRIMARY (pre-flight), MemAvailable on ora-au-lab is at least 4.5 GB (measured about 2.65 GB for 242 holders, plus the 1.5 GB at which the ramp stops adding), the unit does not exist, PROCESSES is between 100 and 600 with less than half in use, the account C##OBENHUB_MON logs in (password of lab/oracle/.env, sent on stdin only) and the receiver series are present. The ramp adds 20 holders at a time, never more than limit - baseline + 30, probes with a fresh bequeath login after each batch, stops at the first ORA or TNS code the probe gets (a login that succeeds at the limit frees its own slot, so reaching the limit is not enough) or at limit - baseline + 30 holders, and stops adding below 1.5 GB MemAvailable. Only CDB19 is touched: CDB19B and CDB26 run on the same VM and their process lists are not changed, but they share its memory and CPU; the scenario records that their PMON processes are up before and after. Fast-start failover is not expected to fire (assumption, to be confirmed by the run: the observer pings the primary and the broker and redo transport talk over sessions and processes that exist before the exhaustion, so no new process is needed). The pair is checked healthy after the revert.
# While the limit is reached the scenario's own ora_sql (a bequeath login) fails too: between the ramp and the revert it reads only from VictoriaMetrics, VictoriaLogs, journald and the OS; failed fresh logins there are results, not aborts.
# Evidence for the planned upstream proposal (ADR 0008 decision 7: pooled sessions hide an exhausted instance; the tcpcheck probe sees the listener only): the record's extra field holds, for the window from the end of the ramp to the stop of the unit, the samples of the oracledb receiver's series (oracledb.processes.usage with its maximum, processes.limit, sessions.usage, cpu_time), of the sql_query heartbeat of both databases and of tcpcheck.status from VictoriaMetrics, the results of fresh logins (ORA or TNS code only: C##OBENHUB_MON through the listener from ora-dg-obs, and a local bequeath sysdba login on ora-au-lab) right after the ramp and after the alert, the error codes the Collector logged (journald on ora-dg-obs; codes and counts only), the number of holders started and of client processes still alive at the end of the ramp (approximate), the minimum and maximum of the process usage and of tcpcheck.status in the window, and the ORA codes mentioned in the CDB19 alert log from the start of the ramp to the end of the revert (codes and counts of mentions only, ORA-20 counted as ORA-00020). The listener may answer ORA-12516, ORA-12519 or ORA-12520 instead of ORA-00020; whichever appears is recorded.
# Refill: background processes of the instance (job queue and MMON slaves) come and go, and each one that ends frees a slot. In suite oracle-20261122T154924Z-e7a36bd usage fell to 317 of 320 before the alert and both fresh logins succeeded. So after the ramp the unit tries one more holder login about every REFILL_EVERY seconds while fewer than max holders (limit - baseline + 30) are alive and MemAvailable is above the ramp's floor; a login still running after 5 s counts as added. The loop ends 60 s before HOLD_CAP and the revert stops everything as before. after_detect waits for an attempt that started after the call before it checks the fresh logins; extra.processes.refill_after_ramp records the attempts and the holders added (null when the journal of the unit cannot be read or has no refill line, as when the revert starts right after the ramp). A slot of a killed server process came free about 30 s later in a live test (2026-11-22, run 4).
# Revert: from the shared exit trap (also on Ctrl-C and when the ramp failed half way), idempotent: systemctl stop of the unit (three attempts), then wait until the processes in use are back within baseline + 10, a fresh login as C##OBENHUB_MON works and the pair is healthy. If the unit cannot be stopped, the holders end by themselves HOLD_CAP seconds after their start.
# shellcheck disable=SC1091,SC2016,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleProcessesSaturation:$PRIMARY_SID")
ALLOW=()
DETECT_DEADLINE=300
HOLD_AFTER_DETECT=45

UNIT=obenhub-processes-exhausted
HOLD_CAP=900
BATCH=20
MIN_AVAIL_KB=4718592
STOP_ADDING_KB=1572864
REFILL_EVERY=3

UNIT_TRIED="" START_AT="" EXHAUSTED_AT="" STOP_AT=""
ORA_HOME="" DIAG="" ALERT_LOG="" ALERT_SIZE=""
LIMIT="" BASE_PROCS="" MAXH="" MEM_BEFORE_KB=""
RAMP_REASON="" RAMP_STARTED=null RAMP_ALIVE=null RAMP_UTIL="" RAMP_CODE="" MEM_RAMP_KB=null
LOGIN_L1="" LOGIN_B1="" LOGIN_L2="" LOGIN_B2="" LOGIN_L3="" LOGIN_B3=""
OTHERS_BEFORE="" OTHERS_AFTER="" PEAK=null PROCS_AFTER=""
ALERT_CODES=null SEV_CRIT=false REFILL=null

# the ramp, then the refill loop, run as oracle inside the unit (env: ORACLE_*,
# MAXH BATCH CAP LIMIT STOP_KB EVERY); its stdout goes to the journal of the unit
read -r -d '' RAMP <<'RAMP_EOF'
holder() { printf 'exec dbms_session.sleep(%s)\nexit\n' "${1:-$CAP}" | sqlplus -s -L '/ as sysdba' >/dev/null 2>&1; }
probe() {
  timeout 60 sqlplus -s -L '/ as sysdba' 2>&1 <<'SQL'
set head off feedback off pages 0
select current_utilization from v$resource_limit where resource_name = 'processes';
exit
SQL
}
started=0 reason=max util= code=
while [ "$started" -lt "$MAXH" ]; do
  avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [ "$avail" -lt "$STOP_KB" ]; then reason=memory; break; fi
  n=$BATCH
  [ $((MAXH - started)) -ge "$n" ] || n=$((MAXH - started))
  for _ in $(seq "$n"); do holder & done
  started=$((started + n))
  sleep 3
  out=$(probe)
  util=$(grep -E -o -m1 '^ *[0-9]+ *$' <<<"$out" | tr -d ' ')
  code=$(grep -E -o 'ORA-[0-9]+|TNS-[0-9]+' <<<"$out" | head -n1)
  echo "ramp started=$started util=${util:-none} code=${code:-none} avail_kb=$avail"
  if [ -n "$code" ]; then reason=exhausted; break; fi
done
echo "ramp done reason=$reason started=$started alive=$(jobs -rp | wc -l) util=${util:-none} code=${code:-none} avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) epoch=$(date +%s)"
# refill: keep the instance exhausted until the unit is stopped. A holder that
# is still running after the login window got a slot; one that exits failed.
added=0 attempts=0
while [ "$SECONDS" -lt $((CAP - 60)) ]; do
  sleep "$EVERY"
  try=$(date +%s) note=none
  alive=$(jobs -rp | wc -l)
  avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [ "$alive" -ge "$MAXH" ]; then note=max
  elif [ "$avail" -lt "$STOP_KB" ]; then note=memory
  else
    attempts=$((attempts + 1))
    holder $((CAP - SECONDS)) &
    pid=$!
    note=full
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.5
      if ! jobs -rp | grep -qx "$pid"; then break; fi
    done
    if jobs -rp | grep -qx "$pid"; then
      added=$((added + 1)) note=added
      echo "refill added epoch=$try alive=$(jobs -rp | wc -l) added=$added"
    fi
  fi
  echo "refill tick try=$try epoch=$(date +%s) alive=$(jobs -rp | wc -l) attempts=$attempts added=$added note=$note"
done
wait
RAMP_EOF

mem_avail_kb() { rn "$PRIMARY_HOST" awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
unit_state() { rn "$PRIMARY_HOST" systemctl show -p ActiveState --value "$UNIT"; }
unit_load() { rn "$PRIMARY_HOST" systemctl show -p LoadState --value "$UNIT"; }
unit_down() { case $(unit_state) in inactive | failed) true ;; *) false ;; esac; }
stop_unit() { rn "$PRIMARY_HOST" systemctl stop "$UNIT" >/dev/null 2>&1; unit_down; }
# the journal of the unit since this run started (the journal keeps the lines
# of earlier runs of the same unit name): the ramp's lines
ramp_log() { rn "$PRIMARY_HOST" journalctl -u "$UNIT" --since "@$START_AT" -o cat --no-pager 2>/dev/null; }
# refill_tried_since EPOCH: the unit has logged a refill attempt that started at or after EPOCH
refill_tried_since() { local t; t=$(ramp_log | sed -n 's/^refill tick try=\([0-9]*\) .*/\1/p' | tail -n1); [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge "$1" ]; }
# refill_summary: JSON of the refill loop from the journal of the unit (after the stop)
refill_summary() {
  local j
  j=$(ramp_log) && grep -q '^refill tick ' <<<"$j" || return 1
  jq -R -s -c '[split("\n")[] | select(startswith("refill "))] as $r
    | [$r[] | select(startswith("refill added")) | capture("epoch=(?<e>[0-9]+)").e | tonumber] as $add
    | [$r[] | select(startswith("refill tick"))] as $t
    | {holders_added: ($add | length), added_epochs: $add, ticks: ($t | length),
       attempts: (($t | last // "") | capture("attempts=(?<a>[0-9]+)").a // "0" | tonumber),
       skipped_max_or_memory: ([$t[] | select(test("note=(max|memory)"))] | length)}' <<<"$j"
}
ramp_done() { ramp_log | grep -q '^ramp done '; }
# procs_state: "<current> <limit>" of the processes resource of the primary
procs_state() { ora_sql "$PRIMARY_SID" <<<"SELECT current_utilization || ' ' || limit_value FROM v\$resource_limit WHERE resource_name = 'processes';" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
procs_back() { local s; s=$(procs_state) && [[ ${s%% *} =~ ^[0-9]+$ ]] && [ "${s%% *}" -le $((BASE_PROCS + 10)) ]; }
mon_ok() { [ "$(mon_login full)" = ok ]; }
# local_login: a fresh bequeath sysdba login on the primary VM; "ok" or the first ORA or TNS code
local_login() {
  local out
  out=$(ora_sql "$PRIMARY_SID" <<<"SELECT 'login-ok' FROM dual;" 2>&1)
  if grep -q 'login-ok' <<<"$out"; then echo ok
  else out=$(grep -E -o 'ORA-[0-9]+|TNS-[0-9]+' <<<"$out" | head -n1); echo "${out:-failed}"; fi
}
# others_up: "CDB19B=<n> CDB26=<n>", the PMON processes of the two other instances on the VM
others_up() {
  local b c
  b=$(rn "$PRIMARY_HOST" pgrep -c -x ora_pmon_cdb19b); c=$(rn "$PRIMARY_HOST" pgrep -c -x ora_pmon_cdb26)
  echo "CDB19B=${b:-0} CDB26=${c:-0}"
}

# pre-flight of this scenario on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local s
  base_pre || return 1
  if ! { [ -r "$LAB_DIR/.env" ] && pw_ok; }; then
    PRE_ERR="lab/oracle/.env is missing or ORA_MON_PASSWORD is not 30 hex characters (the fresh-login checks need it)"
    return 1
  fi
  s=$(unit_load)
  [ -n "$s" ] || { PRE_ERR="cannot read the state of the unit $UNIT on $PRIMARY_HOST (ssh or systemctl failed)"; return 1; }
  [ "$s" = not-found ] || { PRE_ERR="the unit $UNIT already exists on $PRIMARY_HOST (load state $s; stop it first)"; return 1; }
  MEM_BEFORE_KB=$(mem_avail_kb)
  [[ $MEM_BEFORE_KB =~ ^[0-9]+$ ]] || { PRE_ERR="cannot read MemAvailable on $PRIMARY_HOST"; return 1; }
  [ "$MEM_BEFORE_KB" -ge "$MIN_AVAIL_KB" ] || { PRE_ERR="MemAvailable on $PRIMARY_HOST is $((MEM_BEFORE_KB / 1024)) MB, below $((MIN_AVAIL_KB / 1024)) MB"; return 1; }
  s=$(procs_state) || { PRE_ERR="cannot read V\$RESOURCE_LIMIT of $PRIMARY_SID"; return 1; }
  BASE_PROCS=${s%% *} LIMIT=${s##* }
  [[ $BASE_PROCS =~ ^[0-9]+$ && $LIMIT =~ ^[0-9]+$ ]] || { PRE_ERR="unexpected processes state: $s"; return 1; }
  { [ "$LIMIT" -ge 100 ] && [ "$LIMIT" -le 600 ] && [ "$((BASE_PROCS * 2))" -lt "$LIMIT" ]; } || { PRE_ERR="PROCESSES is $LIMIT with $BASE_PROCS in use: outside the range this scenario is sized for (limit 100 to 600, under half in use)"; return 1; }
  MAXH=$((LIMIT - BASE_PROCS + 30))
  ORA_HOME=$(rn "$PRIMARY_HOST" awk -F: -v s="$PRIMARY_SID" '$1==s {print $2}' /etc/oratab)
  [[ $ORA_HOME =~ ^/[A-Za-z0-9_/.-]+$ ]] || { PRE_ERR="cannot read ORACLE_HOME of $PRIMARY_SID from /etc/oratab"; return 1; }
  DIAG=$(ora_sql "$PRIMARY_SID" <<<"SELECT value FROM v\$diag_info WHERE name = 'Diag Trace';" | tr -d '[:space:]')
  ALERT_LOG="$DIAG/alert_$PRIMARY_SID.log"
  [[ $ALERT_LOG =~ ^/[A-Za-z0-9_/.-]+$ ]] || { PRE_ERR="cannot read the diagnostic trace directory of $PRIMARY_SID"; return 1; }
  ALERT_SIZE=$(rn "$PRIMARY_HOST" stat -c %s "$ALERT_LOG")
  [[ $ALERT_SIZE =~ ^[0-9]+$ ]] || { PRE_ERR="cannot read the size of $ALERT_LOG"; return 1; }
  [ "$(mon_login full)" = ok ] || { PRE_ERR="a fresh login as $MON_USER fails before the ramp (the password in lab/oracle/.env differs from the database's?)"; return 1; }
  [ "$(vm_query "count(last_over_time(oracledb.processes.limit{service.instance.id=\"$PRIMARY_SID\"}[1m]))")" -ge 1 ] 2>/dev/null || { PRE_ERR="the oracledb receiver reports no oracledb.processes.limit for $PRIMARY_SID"; return 1; }
  OTHERS_BEFORE=$(others_up)
  log "processes $BASE_PROCS of $LIMIT, at most $MAXH holders; MemAvailable $((MEM_BEFORE_KB / 1024)) MB; ORACLE_HOME $ORA_HOME; $OTHERS_BEFORE"
}

inject() {
  local d
  UNIT_TRIED=1
  START_AT=$(date +%s)
  rn "$PRIMARY_HOST" systemd-run --unit="$UNIT" --collect --quiet --uid=oracle \
    --property=MemoryMax=5G --property=TasksMax=1500 --property=CPUWeight=20 \
    --setenv=ORACLE_SID="$PRIMARY_SID" --setenv=ORACLE_HOME="$ORA_HOME" --setenv=PATH="$ORA_HOME/bin:/usr/bin:/bin" \
    --setenv=MAXH="$MAXH" --setenv=BATCH="$BATCH" --setenv=CAP="$HOLD_CAP" --setenv=LIMIT="$LIMIT" --setenv=STOP_KB="$STOP_ADDING_KB" --setenv=EVERY="$REFILL_EVERY" \
    bash -c "$RAMP" || { FAILS+=("systemd-run of the holder unit failed"); return 1; }
  wait_until 240 "the ramp to finish" ramp_done || { FAILS+=("the ramp did not finish within 240 s"); return 1; }
  d=$(ramp_log | grep '^ramp done ')
  RAMP_REASON=$(sed -n 's/.* reason=\([a-z]*\).*/\1/p' <<<"$d")
  RAMP_STARTED=$(sed -n 's/.* started=\([0-9]*\).*/\1/p' <<<"$d")
  RAMP_ALIVE=$(sed -n 's/.* alive=\([0-9]*\).*/\1/p' <<<"$d")
  RAMP_UTIL=$(sed -n 's/.* util=\([0-9a-z]*\).*/\1/p' <<<"$d")
  RAMP_CODE=$(sed -n 's/.* code=\([A-Za-z0-9-]*\).*/\1/p' <<<"$d")
  MEM_RAMP_KB=$(sed -n 's/.* avail_kb=\([0-9]*\).*/\1/p' <<<"$d")
  EXHAUSTED_AT=$(sed -n 's/.* epoch=\([0-9]*\).*/\1/p' <<<"$d")
  log "ramp: $d"
  : "${RAMP_STARTED:=null}" "${RAMP_ALIVE:=null}" "${MEM_RAMP_KB:=null}"
  [ -n "$EXHAUSTED_AT" ] || EXHAUSTED_AT=$(date +%s)
  case $RAMP_REASON in
    exhausted) ;;
    *) FAILS+=("the ramp ended with reason '$RAMP_REASON' ($RAMP_STARTED holders started, util $RAMP_UTIL) before a fresh login failed"); return 1 ;;
  esac
  LOGIN_L1=$(mon_login full)
  LOGIN_B1=$(local_login)
  log "fresh logins right after the ramp: through the listener as $MON_USER $LOGIN_L1; local bequeath sysdba $LOGIN_B1"
  if [ "$LOGIN_L1" = ok ] && [ "$LOGIN_B1" = ok ]; then FAILS+=("both fresh logins succeed with the processes at the limit: the instance is not exhausted"); return 1; fi
  return 0
}
after_detect() {
  local rc=0 tt
  # the logins observe the state right after a refill attempt of the unit, so
  # a slot freed by an ending background process has been taken again
  tt=$(date +%s)
  wait_until 30 "a refill attempt after $tt" refill_tried_since "$tt" || log "no refill attempt logged after $tt; checking the logins anyway"
  LOGIN_L2=$(mon_login full)
  LOGIN_B2=$(local_login)
  log "fresh logins after the alert: through the listener $LOGIN_L2; local bequeath sysdba $LOGIN_B2"
  if [ "$LOGIN_L2" = ok ] && [ "$LOGIN_B2" = ok ]; then FAILS+=("both fresh logins succeed after the alert"); rc=1; fi
  # the warning tier may be delivered first (a scrape inside the band during the ramp); the critical one follows within the window
  if wait_until 120 "OracleProcessesSaturation critical delivered" severity_seen OracleProcessesSaturation "$PRIMARY_SID" "$T_INJECT" critical; then SEV_CRIT=true
  else FAILS+=("OracleProcessesSaturation was not delivered as critical"); rc=1; fi
  return "$rc"
}
revert() {
  local rc=0 s
  [ -n "$UNIT_TRIED" ] || return 0
  [ -n "$STOP_AT" ] || STOP_AT=$(date +%s)
  retry stop_unit || { FAILS+=("systemctl stop $UNIT failed three times: the holders end by themselves $HOLD_CAP s after their start"); return 1; }
  log "holder unit stopped"
  REFILL=$(refill_summary) || REFILL=null
  log "refill: $REFILL"
  wait_until 120 "processes in use back within $((BASE_PROCS + 10))" procs_back || { FAILS+=("processes in use not back within baseline + 10 (baseline $BASE_PROCS) 120 s after the stop"); rc=1; }
  PROCS_AFTER=$(procs_state) || PROCS_AFTER=unreadable
  wait_until 60 "fresh login as $MON_USER" mon_ok || { FAILS+=("fresh login as $MON_USER fails 60 s after the stop"); rc=1; }
  LOGIN_L3=$(mon_login full)
  LOGIN_B3=$(local_login)
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the stop"); rc=1; }
  OTHERS_AFTER=$(others_up)
  [ "$OTHERS_AFTER" = "$OTHERS_BEFORE" ] || { FAILS+=("other instances on the VM changed: $OTHERS_BEFORE before, $OTHERS_AFTER after"); rc=1; }
  # ORA codes of the alert log from the start of the ramp to here (codes and counts only)
  # Mentions, not events: one ORA-00020 writes the error line and, in the
  # message that follows it, "ORA-20" twice; the number is padded to five
  # digits so that both spellings count under ORA-00020 (three mentions per
  # event). No code at all is {}, an unreadable log is null.
  if s=$(rn "$PRIMARY_HOST" bash -c "set -o pipefail; tail -c +$((ALERT_SIZE + 1)) '$ALERT_LOG' | { grep -E -o 'ORA-[0-9]+|TNS-[0-9]+' || [ \$? -eq 1 ]; } | sort | uniq -c"); then
    ALERT_CODES=$(printf '%s\n' "$s" | sed -E 's/^ *([0-9]+) (ORA|TNS)-([0-9]+)$/\1\t\2-\3/' \
      | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | (.[1] | split("-")) as $c | {key: ($c[0] + "-" + ("00000" + $c[1])[-5:]), value: (.[0] | tonumber)})
        | group_by(.key) | map({(.[0].key): (map(.value) | add)}) | add // {}') || ALERT_CODES=null
  else ALERT_CODES=null; fi
  return "$rc"
}

extra_checks() {
  local a=$EXHAUSTED_AT b=$STOP_AT sess proc lim cpu hb hbs tc err peak pwin tcv
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the oracledb receiver (C##OBENHUB_MON, 30 s)
  sess=$(series_stats "oracledb.sessions.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || sess=null
  proc=$(series_stats "oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || proc=null
  lim=$(series_stats "oracledb.processes.limit{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || lim=null
  cpu=$(series_stats "oracledb.cpu_time{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || cpu=null
  # values, not only sample counts: min, max and number of samples in the window
  peak=$(series_max "oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}" "$START_AT" "$b") || peak=null
  pwin=$(series_max "oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || pwin=null
  tcv=$(series_max "tcpcheck.status{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || tcv=null
  # the sql_query heartbeat (C##OBENHUB_DG as SYSDG, 15 s); the standby is the control
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "$b" 15) || hbs=null
  tc=$(series_stats "tcpcheck.status{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || tc=null
  err=$(collector_errors "$a" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson a "$a" --argjson b "$b" --argjson s0 "$START_AT" --argjson sess "${sess:-null}" --argjson proc "${proc:-null}" \
    --argjson lim "${lim:-null}" --argjson cpu "${cpu:-null}" --argjson peak "${peak:-null}" --argjson pwin "${pwin:-null}" --argjson tcv "${tcv:-null}" --argjson hb "${hb:-null}" --argjson hbs "${hbs:-null}" \
    --argjson tc "${tc:-null}" --argjson err "${err:-null}" --argjson alertlog "${ALERT_CODES:-null}" --argjson refill "${REFILL:-null}" \
    --argjson started "${RAMP_STARTED:-null}" --argjson alive "${RAMP_ALIVE:-null}" --argjson mem1 "${MEM_BEFORE_KB:-null}" --argjson mem2 "${MEM_RAMP_KB:-null}" \
    --argjson limit "${LIMIT:-null}" --argjson base "${BASE_PROCS:-null}" --argjson maxh "${MAXH:-null}" --argjson crit "$SEV_CRIT" \
    --arg reason "$RAMP_REASON" --arg code "$RAMP_CODE" --arg util "$RAMP_UTIL" --arg procs_after "$PROCS_AFTER" \
    --arg l1 "$LOGIN_L1" --arg l2 "$LOGIN_L2" --arg l3 "$LOGIN_L3" --arg b1 "$LOGIN_B1" --arg b2 "$LOGIN_B2" --arg b3 "$LOGIN_B3" \
    --arg o1 "$OTHERS_BEFORE" --arg o2 "$OTHERS_AFTER" \
    '{start_epoch: $s0, exhausted_epoch: $a, stop_epoch: $b, exhausted_s: ($b - $a),
      processes: {limit: $limit, baseline: $base, max_holders: $maxh, holders_started: $started, client_processes_alive_at_ramp_end_approx: $alive,
                  ramp_reason: $reason, ramp_probe_code: $code, ramp_probe_util: $util, usage_values_start_to_stop: $peak, usage_values_exhausted_window: $pwin, after_stop: $procs_after, refill_after_ramp: $refill},
      mem_available_kb: {before: $mem1, ramp_end: $mem2},
      oracledb_receiver: {sessions_usage: $sess, processes_usage: $proc, processes_limit: $lim, cpu_time: $cpu},
      heartbeat_primary: $hb, heartbeat_standby: $hbs, tcpcheck_primary: $tc, tcpcheck_status_values_exhausted_window: $tcv, collector_log: $err,
      fresh_login_listener_as_mon: {right_after_ramp: $l1, after_alert: $l2, after_stop: $l3},
      fresh_login_bequeath_sysdba: {right_after_ramp: $b1, after_alert: $b2, after_stop: $b3},
      alert_log_code_mentions_ramp_to_revert: $alertlog, critical_delivered: $crit,
      other_instances: {before: $o1, after: $o2}}')
  log "extra: $EXTRA_JSON"
}
run_scenario processes-exhausted
