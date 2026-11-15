#!/usr/bin/env bash
# Scenario blocking-session: one session of the pluggable database PDB19 of the CDB19 primary on ora-au-lab waits for a row lock that another session holds. The scenario creates the user OBENHUB_BLOCK (no authentication, quota of 1 MB on the PDB's default permanent tablespace) with one table of one row, as sysdba with operating-system authentication inside PDB19 (ALTER SESSION SET CONTAINER). Two background `sqlplus -s / as sysdba` sessions run in one transient systemd unit on ora-au-lab (UNIT, as processes-exhausted.sh): holder A updates the row and sleeps (`dbms_session.sleep(HOLD_CAP)`) without committing, five seconds later waiter B updates the same row and waits in `enq: TX - row lock contention` (wait class Application). Nothing else is touched: no existing user, table, tablespace or parameter is changed, and the CDB root is only the sessions' starting container.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml: the sql_query receiver on the primary (C##OBENHUB_DG as SYSDG, 15 s, queries-primary.yaml) reports oracledb.lock.oldest_wait_age, the seconds the longest waiter has waited (0 when none), read from V$SESSION at the CDB root, where the sessions of PDB19 are listed. The value grows with the wait; OracleBlockedSessions (one warning tier) fires for CDB19 once three 15 s points in a row are above 30 s, so the wait is about a minute old, and Alertmanager's grouping adds to that. Nothing else is expected: ALLOW stays empty and any other alert is reported as unexpected. Before the alert is waited for, the scenario reads V$SESSION itself and requires the waiter to be blocked (BLOCKING_SESSION set, state WAITING, class Application, container PDB19); after the alert it requires the same blocker and a longer wait. The table is the one the sessions lock; nothing is written to the standby but the redo of the create and the drop of the user and table.
# Guard: besides the shared pre-flight (pair healthy, receivers flowing) the run refuses to start unless CDB19 is the PRIMARY (pre-flight), the broker reports the pair SYNCHRONIZED with fast-start failover enabled, PDB19 is READ WRITE on the primary, its default permanent tablespace has at least 2 MB free, the user OBENHUB_BLOCK does not exist (so a name that exists is never ours and never dropped), the unit does not exist, no session of the primary is waiting on a lock now (Application class with a blocker), and the receiver already reports oracledb.lock.oldest_wait_age for CDB19 with the value 0 (the Collector config of this change is deployed: mise run lab:oracle:collector). The pair is checked healthy after the revert and the lag at three points is recorded. The existing Data Guard lag and gap alerts must stay quiet: any alert besides OracleBlockedSessions is reported as unexpected.
# Revert: from the shared exit trap (also on Ctrl-C and when the inject failed half way), idempotent, three attempts each: systemctl stop of the unit (the killed sessions roll back; both ends of a bequeath session die with it), then DROP USER OBENHUB_BLOCK CASCADE inside PDB19 when it exists (it can fail with ORA-00054 for a few seconds while the killed sessions are cleaned up, hence the wait until no lock is left on its objects and the retries), then a late re-check after a pause for an interrupted create or unit start that finished late. If the stop fails the holders end by themselves HOLD_CAP seconds after their start; if the drop fails the user and its one-row table stay and are named in the failure reason.
# shellcheck disable=SC1091,SC2016,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleBlockedSessions:$PRIMARY_SID")
ALLOW=()
DETECT_DEADLINE=300
HOLD_AFTER_DETECT=30

PDB=PDB19
OWNER=OBENHUB_BLOCK
TBL=LOCK_T
UNIT=obenhub-blocking-session
HOLD_CAP=900
MIN_FREE_MB=2

TRIED="" UNIT_TRIED="" CREATE_AT="" START_AT="" BLOCKED_AT="" RELEASE_AT=""
DEF_TS="" ORA_HOME=""
BLOCK_ROW="" BLOCK_ROW2="" BLOCKER_EVENT="" BLOCKER_EVENT2=""
WAIT1=null WAIT2=null SERIES_AT_ALERT=null
LAG_BEFORE="" LAG_DURING="" LAG_AFTER=""
LEFT_LOCKS=null

# the sessions, run as oracle inside the unit (env: ORACLE_*, PDB OWNER TBL CAP);
# their output goes to the journal of the unit
read -r -d '' HOLD <<'HOLD_EOF'
holder() {
  printf 'whenever sqlerror exit failure\nalter session set container = %s;\nupdate %s.%s set v = v + 1 where id = 1;\nexec dbms_session.sleep(%s)\nexit\n' "$PDB" "$OWNER" "$TBL" "$CAP" | sqlplus -s -L '/ as sysdba' 2>&1
  echo "holder A ended rc=$? epoch=$(date +%s)"
}
waiter() {
  printf 'whenever sqlerror exit failure\nalter session set container = %s;\nupdate %s.%s set v = v + 1 where id = 1;\nrollback;\nexit\n' "$PDB" "$OWNER" "$TBL" | sqlplus -s -L '/ as sysdba' 2>&1
  echo "waiter B ended rc=$? epoch=$(date +%s)"
}
holder & echo "holder A started epoch=$(date +%s)"
sleep 5
waiter & echo "waiter B started epoch=$(date +%s)"
wait
HOLD_EOF

# series_first_positive SELECTOR START END: time (epoch) and value of the first sample above 0 in the window, as JSON, null when none
series_first_positive() {
  curl -fsS "$VM/api/v1/export" --data-urlencode "match[]=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" \
    | jq -s -c '[.[] | [.timestamps, .values] | transpose[] | select(.[1] > 0) | {epoch: (.[0] / 1000 | floor), value: .[1]}] | sort_by(.epoch) | .[0] // null'
}
# alert_starts_at: startsAt of the first firing notification of the expected alert (the time vmalert started it), from the Alertmanager notification record in VictoriaLogs
alert_starts_at() {
  vl "_time:>$T_INJECT status:=firing commonLabels.alertname:=OracleBlockedSessions commonLabels.service_instance_id:=$PRIMARY_SID | sort by (_time) | limit 1 | fields alerts" \
    | jq -r '.alerts | fromjson | .[0].startsAt' | head -n1
}

unit_state() { rn "$PRIMARY_HOST" systemctl show -p ActiveState --value "$UNIT"; }
unit_load() { rn "$PRIMARY_HOST" systemctl show -p LoadState --value "$UNIT"; }
unit_down() { case $(unit_state) in inactive | failed) true ;; *) false ;; esac; }
stop_unit() { rn "$PRIMARY_HOST" systemctl stop "$UNIT" >/dev/null 2>&1; unit_down; }
unit_log() { rn "$PRIMARY_HOST" journalctl -u "$UNIT" --since "@$START_AT" -o cat --no-pager 2>/dev/null; }

user_count() { in_pdb <<<"SELECT COUNT(*) FROM dba_users WHERE username = '$OWNER';" | tr -d '[:space:]'; }
# locked_count: locks held on objects of the scenario's user (V$LOCKED_OBJECT of the PDB)
locked_count() { in_pdb <<<"SELECT COUNT(*) FROM v\$locked_object lo JOIN dba_objects o ON o.object_id = lo.object_id WHERE o.owner = '$OWNER';" | tr -d '[:space:]'; }
unlocked() { [ "$(locked_count)" = 0 ]; }
drop_all() {
  in_pdb >/dev/null <<SQL
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = '$OWNER';
  IF n > 0 THEN EXECUTE IMMEDIATE 'DROP USER $OWNER CASCADE'; END IF;
END;
/
SQL
}
gone() { [ "$(user_count)" = 0 ]; }
# blocked_now: the longest waiter of wait class Application that has a blocker, the predicate of the
# sql_query of queries-primary.yaml, read as sysdba at the CDB root:
# "<container> <waiter sid> <blocker sid> <class> <event> <seconds waited> <owner.table waited on>", empty when none
# (ROW_WAIT_OBJ# names the table of a row lock wait; CDB_OBJECTS is read at the root for every container)
blocked_now() {
  ora_sql "$PRIMARY_SID" <<'SQL' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
SELECT NVL((SELECT c.name FROM v$containers c WHERE c.con_id = s.con_id), '?') || ' ' || s.sid || ' ' || s.blocking_session || ' ' ||
       REPLACE(s.wait_class, ' ', '_') || ' ' || REPLACE(s.event, ' ', '_') || ' ' || ROUND(s.wait_time_micro / 1000000, 1) || ' ' ||
       NVL((SELECT o.owner || '.' || o.object_name FROM cdb_objects o WHERE o.con_id = s.con_id AND o.object_id = s.row_wait_obj#), '-')
FROM v$session s
WHERE s.blocking_session IS NOT NULL AND s.state = 'WAITING' AND s.wait_class = 'Application'
ORDER BY s.wait_time_micro DESC FETCH FIRST 1 ROW ONLY;
SQL
}
blocked_seen() { local r; r=$(blocked_now) && [ -n "$r" ] && BLOCK_ROW=$r; }
# event_of SID: the wait event of a session (the blocker's), spaces as underscores
event_of() { ora_sql "$PRIMARY_SID" <<<"SELECT REPLACE(event, ' ', '_') FROM v\$session WHERE sid = $1;" | tr -d '[:space:]'; }

# pre-flight of this scenario on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local s v
  base_pre || return 1
  sync_ok || { PRE_ERR="the pair is not SYNCHRONIZED (protection level and fast-start failover status)"; return 1; }
  s=$(ora_sql "$PRIMARY_SID" <<<"SELECT open_mode FROM v\$containers WHERE name = '$PDB';" | tr -d '\r') || { PRE_ERR="cannot read $PDB of $PRIMARY_SID"; return 1; }
  [ "$s" = 'READ WRITE' ] || { PRE_ERR="$PDB on $PRIMARY_SID is '$s', not READ WRITE"; return 1; }
  DEF_TS=$(in_pdb <<<"SELECT property_value FROM database_properties WHERE property_name = 'DEFAULT_PERMANENT_TABLESPACE';" | tr -d '[:space:]')
  [[ $DEF_TS =~ ^[A-Z][A-Z0-9_]*$ ]] || { PRE_ERR="cannot read the default permanent tablespace of $PDB: '$DEF_TS'"; return 1; }
  v=$(in_pdb <<<"SELECT NVL(ROUND(SUM(bytes) / 1048576), 0) FROM dba_free_space WHERE tablespace_name = '$DEF_TS';" | tr -d '[:space:]')
  { [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$MIN_FREE_MB" ]; } || { PRE_ERR="less than $MIN_FREE_MB MB free (or unreadable) in $DEF_TS of $PDB: '$v'"; return 1; }
  [ "$(user_count)" = 0 ] || { PRE_ERR="user $OWNER already exists in $PDB (not created by this run, not dropped)"; return 1; }
  s=$(unit_load)
  [ -n "$s" ] || { PRE_ERR="cannot read the state of the unit $UNIT on $PRIMARY_HOST (ssh or systemctl failed)"; return 1; }
  [ "$s" = not-found ] || { PRE_ERR="the unit $UNIT already exists on $PRIMARY_HOST (load state $s; stop it first)"; return 1; }
  ORA_HOME=$(rn "$PRIMARY_HOST" awk -F: -v s="$PRIMARY_SID" '$1==s {print $2}' /etc/oratab)
  [[ $ORA_HOME =~ ^/[A-Za-z0-9_/.-]+$ ]] || { PRE_ERR="cannot read ORACLE_HOME of $PRIMARY_SID from /etc/oratab"; return 1; }
  s=$(blocked_now) || { PRE_ERR="cannot read V\$SESSION of $PRIMARY_SID"; return 1; }
  [ -z "$s" ] || { PRE_ERR="a session of $PRIMARY_SID is already waiting on a lock: $s"; return 1; }
  v=$(vm_query "max(last_over_time(oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}[1m]))")
  [ "$v" = 0 ] || { PRE_ERR="the receiver reports oracledb.lock.oldest_wait_age '${v:-none}' for $PRIMARY_SID, not 0 (lab/packs/oracledb-dg/queries-primary.yaml deployed? lab:oracle:collector)"; return 1; }
  LAG_BEFORE=$(lag_pair)
  log "$PDB default tablespace $DEF_TS; ORACLE_HOME $ORA_HOME; lag before (transport apply) $LAG_BEFORE"
}

inject() {
  TRIED=1
  CREATE_AT=$(date +%s)
  in_pdb >/dev/null <<SQL || { FAILS+=("creating $OWNER or $OWNER.$TBL failed"); return 1; }
CREATE USER $OWNER NO AUTHENTICATION QUOTA 1M ON $DEF_TS;
CREATE TABLE $OWNER.$TBL (id NUMBER PRIMARY KEY, v NUMBER) TABLESPACE $DEF_TS;
INSERT INTO $OWNER.$TBL VALUES (1, 0);
COMMIT;
SQL
  log "created $OWNER.$TBL (one row) in $PDB"
  UNIT_TRIED=1
  START_AT=$(date +%s)
  rn "$PRIMARY_HOST" systemd-run --unit="$UNIT" --collect --quiet --uid=oracle \
    --property=MemoryMax=1G --property=TasksMax=100 --property=CPUWeight=20 \
    --setenv=ORACLE_SID="$PRIMARY_SID" --setenv=ORACLE_HOME="$ORA_HOME" --setenv=PATH="$ORA_HOME/bin:/usr/bin:/bin" \
    --setenv=PDB="$PDB" --setenv=OWNER="$OWNER" --setenv=TBL="$TBL" --setenv=CAP="$HOLD_CAP" \
    bash -c "$HOLD" || { FAILS+=("systemd-run of the holder unit failed"); return 1; }
  # the waiter is started 5 s after the holder; it must show up blocked
  if ! wait_until 90 "the waiter blocked in V\$SESSION" blocked_seen; then
    FAILS+=("no session of $PDB is waiting for a lock (Application class, with a blocker) 90 s after the start; unit journal: $(unit_log | tail -n 4 | tr '\n' '|')")
    return 1
  fi
  BLOCKED_AT=$(date +%s)
  local pdb waiter blocker class event w obj
  read -r pdb waiter blocker class event w obj <<<"$BLOCK_ROW"
  [[ $w =~ ^[0-9.]+$ ]] || { FAILS+=("the first reading of the wait is not a number: '$w'"); return 1; }
  WAIT1=$w
  BLOCKER_EVENT=$(event_of "$blocker")
  log "blocked: container $pdb, waiter sid $waiter, blocker sid $blocker (event $BLOCKER_EVENT), class $class, event $event, waited ${w}s, on $obj"
  [ "$pdb" = "$PDB" ] || { FAILS+=("the blocked session is in container '$pdb', not $PDB"); return 1; }
  [ "$class" = Application ] || { FAILS+=("the blocked session waits in class '$class', not Application"); return 1; }
  # the waiter must be the scenario's own: it waits for a row of the scenario's table
  [ "$obj" = "$OWNER.$TBL" ] || { FAILS+=("the longest waiter (sid $waiter) waits on '$obj', not on $OWNER.$TBL: not this scenario's session"); return 1; }
  return 0
}
after_detect() {
  local rc=0 pdb waiter blocker class event w obj s s1
  BLOCK_ROW2=$(blocked_now)
  read -r pdb waiter blocker class event w obj <<<"$BLOCK_ROW2"
  WAIT2=${w:-null}
  [[ $w =~ ^[0-9.]+$ ]] || WAIT2=null
  log "after the alert: waiter sid ${waiter:-none}, blocker sid ${blocker:-none}, waited ${w:-none}s"
  [ -n "$BLOCK_ROW2" ] || { FAILS+=("no session is waiting for a lock after the alert was delivered"); return 1; }
  read -r _ s1 s _ _ _ _ <<<"$BLOCK_ROW"
  [ "$obj" = "$OWNER.$TBL" ] || { FAILS+=("after the alert the longest waiter (sid $waiter) waits on '$obj', not on $OWNER.$TBL"); rc=1; }
  [ "$waiter" = "$s1" ] || { FAILS+=("the longest waiter changed from sid $s1 to sid $waiter between the first reading and the alert"); rc=1; }
  [ "$blocker" = "$s" ] || { FAILS+=("the blocker changed from sid $s to sid $blocker between the first reading and the alert"); rc=1; }
  awk -v a="$w" -v b="$WAIT1" 'BEGIN{exit !(a > 30 && a > b)}' || { FAILS+=("the wait read after the alert ($w s) is not above 30 s and longer than the first reading ($WAIT1 s)"); rc=1; }
  BLOCKER_EVENT2=$(event_of "$blocker")
  # what the receiver reported last: the series the rule reads (an instant query
  # ignores the newest 30 s by default, -search.latencyOffset: assumption, from
  # the trial of 2026-11-15T01:39:52Z, where it read 79.8 while the database read 121.9)
  s=$(vm_query "max(last_over_time(oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}[30s]))")
  SERIES_AT_ALERT=${s:-null}
  log "oracledb.lock.oldest_wait_age at the alert: ${s:-none}"
  awk -v a="${s:-0}" 'BEGIN{exit !(a > 30)}' || { FAILS+=("oracledb.lock.oldest_wait_age is '${s:-none}' after the alert, not above 30"); rc=1; }
  LAG_DURING=$(lag_pair)
  return "$rc"
}
revert() {
  local rc=0
  [ -n "$TRIED" ] || return 0
  RELEASE_AT=$(date +%s)
  retry stop_unit || { FAILS+=("systemctl stop $UNIT failed three times: the sessions end by themselves $HOLD_CAP s after their start and $OWNER stays until they have"); return 1; }
  log "holder unit stopped"
  wait_until 60 "no lock left on the objects of $OWNER" unlocked || { FAILS+=("locks on the objects of $OWNER still held 60 s after the stop"); rc=1; }
  LEFT_LOCKS=$(locked_count) || LEFT_LOCKS=null
  : "${LEFT_LOCKS:=null}"
  retry drop_all || { FAILS+=("dropping $OWNER in $PDB failed three times: the user and its table are left on $PRIMARY_HOST"); return 1; }
  wait_until 60 "$OWNER gone from $PDB" gone || { FAILS+=("$OWNER still present in $PDB 60 s after the drop"); rc=1; }
  # a create or a unit start cut short by Ctrl-C may still be running remotely: look again after a pause
  sleep 10
  if ! { gone && unit_down; }; then
    log "user or unit appeared after the first drop (an interrupted step finished late): stopping and dropping again"
    retry stop_unit || { FAILS+=("the second stop of $UNIT failed three times"); return 1; }
    wait_until 60 "no lock left on the objects of $OWNER (second stop)" unlocked || rc=1
    retry drop_all || { FAILS+=("the second drop of $OWNER in $PDB failed three times: the user is left on $PRIMARY_HOST"); return 1; }
    wait_until 60 "$OWNER gone from $PDB (second drop)" gone || { FAILS+=("$OWNER still present in $PDB 60 s after the second drop"); rc=1; }
  fi
  log "dropped; user count $(user_count), unit $(unit_state)"
  # the drop reaches the standby by redo: switch a log so that it is shipped now
  log_switch || true
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the drop"); rc=1; }
  LAG_AFTER=$(lag_pair)
  return "$rc"
}

extra_checks() {
  local a=$START_AT b=$RELEASE_AT series_hold hold base after hb hbs err first starts starts_s=null delivered_s=null
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the sql_query receiver (C##OBENHUB_DG as SYSDG, 15 s): the series the rule reads, over the hold, before it and after the release
  series_hold=$(series_stats "oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || series_hold=null
  hold=$(series_max "oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || hold=null
  base=$(series_max "oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}" "$((CREATE_AT - 120))" "$CREATE_AT") || base=null
  after=$(series_max "oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}" "$((b + 45))" "$(date +%s)") || after=null
  first=$(series_first_positive "oracledb.lock.oldest_wait_age{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || first=null
  starts=$(alert_starts_at) || starts=""
  if [ -n "$starts" ] && [ "$starts" != null ]; then
    starts_s=$(date -u -d "$starts" +%s) || starts_s=null
    [ -z "$T_DETECT" ] || delivered_s=$(awk -v a="$(epoch "$starts")" -v b="$(epoch "$T_DETECT")" 'BEGIN{printf "%.1f", b - a}')
  fi
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "$b" 15) || hbs=null
  err=$(collector_errors "$CREATE_AT" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson c "$CREATE_AT" --argjson a "$a" --argjson k "${BLOCKED_AT:-null}" --argjson b "$b" --argjson series_hold "${series_hold:-null}" --argjson hold "${hold:-null}" \
    --argjson base "${base:-null}" --argjson after "${after:-null}" --argjson first "${first:-null}" --argjson starts_s "$starts_s" --argjson delivered_s "$delivered_s" --argjson hb "${hb:-null}" --argjson hbs "${hbs:-null}" --argjson err "${err:-null}" \
    --argjson w1 "${WAIT1:-null}" --argjson w2 "${WAIT2:-null}" --argjson sa "${SERIES_AT_ALERT:-null}" --argjson left "${LEFT_LOCKS:-null}" \
    --arg pdb "$PDB" --arg owner "$OWNER" --arg ts "$DEF_TS" --arg row1 "$BLOCK_ROW" --arg row2 "$BLOCK_ROW2" --arg be1 "$BLOCKER_EVENT" --arg be2 "$BLOCKER_EVENT2" \
    --arg l0 "$LAG_BEFORE" --arg l1 "$LAG_DURING" --arg l2 "$LAG_AFTER" \
    '{pdb: $pdb, user: $owner, tablespace: $ts, create_epoch: $c, start_epoch: $a, blocked_epoch: $k, release_epoch: $b, held_s: ($b - $a),
      blocked_session: {first_reading: $row1, after_alert: $row2, waited_first_s: $w1, waited_after_alert_s: $w2, blocker_event_first: $be1, blocker_event_after_alert: $be2},
      locks_left_after_stop: $left,
      oracle_lock_oldest_wait_age: {series_hold: $series_hold, values_hold: $hold, first_positive_sample: $first, values_before_start_120s: $base, values_after_release: $after, last_value_at_alert: $sa},
      alert: {starts_at_epoch: $starts_s, starts_to_delivered_s: $delivered_s, blocked_to_starts_s: (if $starts_s != null and $k != null then $starts_s - $k else null end)},
      heartbeat_primary: $hb, heartbeat_standby: $hbs, collector_log: $err,
      lag_transport_apply_s: {before: $l0, during: $l1, after_drop: $l2}}')
  log "extra: $EXTRA_JSON"
}
run_scenario blocking-session
