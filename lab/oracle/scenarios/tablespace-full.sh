#!/usr/bin/env bash
# Scenario tablespace-full: a small tablespace of the pluggable database PDB19 of the CDB19 primary on ora-au-lab runs out of space. The scenario creates the tablespace OBENHUB_FILL (one datafile of 20 MB, AUTOEXTEND OFF, uniform extents of 128 KB, in the directory of the PDB's own datafiles) and the user OBENHUB_FILL_OWNER (no authentication, quota on that tablespace only) with one table in it, and inserts rows of about 2 KB, as sysdba with operating-system authentication inside PDB19 (ALTER SESSION SET CONTAINER), until the insert fails with ORA-01653 (a table cannot get a new extent; ORA-01688 is accepted too, it is the partition variant). Nothing else is touched: no existing tablespace, datafile, user or parameter is changed, and the CDB root is only the session's starting container.
# Expectation, derived from lab/packs/oracledb-dg/rules.yml: the oracledb receiver (C##OBENHUB_MON, a pooled session, 30 s, with oracle.db.pdb on the tablespace metrics, lab/oracle/files/otelcol-obs.yaml) reports oracledb.tablespace_size.usage and .limit for OBENHUB_FILL of PDB19; the limit is the datafile size (no autoextend), the ratio reaches 1 (the recorded runs read 1.0 with 2560 of 2560 blocks used while the table segment holds 19922944 bytes, 95% of the file; the 128 blocks, 1 MB, that Oracle reserves in a new 20 MB datafile are counted as used, which an interactive sqlplus observation of 2026-11-14, not a recorded measurement, also showed for an empty tablespace: 128 of 2560 blocks, 0.05) and OracleTablespaceUsageHigh fires for CDB19 as critical. EXPECT matches alertname and instance, not severity, so both tiers are covered by the one entry; the critical tier is asserted in after_detect (severity_seen). The fill takes seconds, shorter than the 90 s window, so the warning tier is not expected to be delivered (a warning delivery is no failure, a missing critical one is). ALLOW stays empty because the warning shares the name. Nothing else is expected, and any other alert is reported as unexpected. The size of the ratio at the end of the fill is read from the database and recorded; it must be at least 0.95 or the run fails.
# Guard: besides the shared pre-flight (pair healthy, receivers flowing) the run refuses to start unless CDB19 is the PRIMARY (pre-flight), the broker reports the pair SYNCHRONIZED with fast-start failover enabled, STANDBY_FILE_MANAGEMENT is AUTO on both databases (a file created or dropped on the primary is then created or dropped on the standby by redo apply; with MANUAL the drop would leave the standby's apply stopped, so the scenario stops), PDB19 is READ WRITE on the primary, neither the tablespace, the user nor the datafile exists on either VM (so a name that exists is never ours and never dropped), the directory of the PDB's datafiles exists on both VMs with at least 1 GB free, and the receiver already reports the tablespace series with the oracle.db.pdb label for PDB19 (the Collector config of this change is deployed: mise run lab:oracle:collector). The redo of the create, the fill (about 20 MB) and the drop reaches the standby over the existing transport; the pair is checked healthy after the revert, and the lag at three points is recorded. The existing Data Guard lag and gap alerts must stay quiet: any alert besides OracleTablespaceUsageHigh is reported as unexpected.
# Revert: from the shared exit trap (also on Ctrl-C and when the inject failed half way), idempotent, three attempts: DROP USER OBENHUB_FILL_OWNER CASCADE and DROP TABLESPACE OBENHUB_FILL INCLUDING CONTENTS AND DATAFILES inside PDB19, each only if it exists; then the datafile must be gone on the primary and, after redo apply, on the standby, and the pair healthy. If the revert fails the objects may stay: they hold 20 MB and are named in the failure reason.
# shellcheck disable=SC1091,SC2016,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleTablespaceUsageHigh:$PRIMARY_SID")
ALLOW=()
DETECT_DEADLINE=300
HOLD_AFTER_DETECT=30

PDB=PDB19
TS=OBENHUB_FILL
OWNER=OBENHUB_FILL_OWNER
TBL=FILL_T
FILL_CAP_ITER=2000
FILL_BATCH=50

TRIED="" CREATE_AT="" FILL_AT="" DROP_AT=""
DF_DIR="" DF=""
SFM_P="" SFM_S=""
FILL_CODE="" FILL_ROWS=null FILL_SECS=null
USED_BLOCKS=null SIZE_BLOCKS=null BLOCK_SIZE=null RATIO=null SEG_BYTES=null ROWS_DB=null
STBY_FILE_DURING="" STBY_FILE_AFTER="" PRIM_FILE_AFTER=""
LAG_BEFORE="" LAG_DURING="" LAG_AFTER=""
RETRY_CODE="" SEV_CRIT=false

param() { ora_sql "$1" <<<"SELECT value FROM v\$parameter WHERE name = 'standby_file_management';" | tr -d '[:space:]'; }
# exists_count: how many of tablespace, user and (primary and standby) datafile entries exist
ts_count() { in_pdb <<<"SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name = '$TS';" | tr -d '[:space:]'; }
user_count() { in_pdb <<<"SELECT COUNT(*) FROM dba_users WHERE username = '$OWNER';" | tr -d '[:space:]'; }
# df_known SID: entries of the datafile in V$DATAFILE of that database (a mounted standby answers too)
df_known() { ora_sql "$1" <<<"SELECT COUNT(*) FROM v\$datafile WHERE name = '$DF';" | tr -d '[:space:]'; }
file_absent() { rn "$1" test ! -e "$DF"; }
free_gb() { rn "$1" df -BG --output=avail "$DF_DIR" | tail -n1 | tr -d '[:space:]G'; }
dir_ok() { rn "$1" test -d "$DF_DIR"; }

drop_all() {
  in_pdb >/dev/null <<SQL
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = '$OWNER';
  IF n > 0 THEN EXECUTE IMMEDIATE 'DROP USER $OWNER CASCADE'; END IF;
  SELECT COUNT(*) INTO n FROM dba_tablespaces WHERE tablespace_name = '$TS';
  IF n > 0 THEN EXECUTE IMMEDIATE 'DROP TABLESPACE $TS INCLUDING CONTENTS AND DATAFILES'; END IF;
END;
/
SQL
}
gone() { [ "$(ts_count)" = 0 ] && [ "$(user_count)" = 0 ] && file_absent "$PRIMARY_HOST"; }
stby_known() { [ "$(df_known "$STANDBY_SID")" = 1 ]; }
stby_gone() { file_absent "$STANDBY_HOST" && [ "$(df_known "$STANDBY_SID")" = 0 ]; }

# pre-flight of this scenario on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local s a b
  base_pre || return 1
  sync_ok || { PRE_ERR="the pair is not SYNCHRONIZED (protection level and fast-start failover status)"; return 1; }
  SFM_P=$(param "$PRIMARY_SID") || { PRE_ERR="cannot read standby_file_management of $PRIMARY_SID"; return 1; }
  SFM_S=$(param "$STANDBY_SID") || { PRE_ERR="cannot read standby_file_management of $STANDBY_SID"; return 1; }
  { [ "$SFM_P" = AUTO ] && [ "$SFM_S" = AUTO ]; } || { PRE_ERR="STANDBY_FILE_MANAGEMENT is '$SFM_P' on $PRIMARY_SID and '$SFM_S' on $STANDBY_SID, not AUTO on both: a datafile dropped on the primary would stop redo apply on the standby"; return 1; }
  s=$(ora_sql "$PRIMARY_SID" <<<"SELECT open_mode FROM v\$containers WHERE name = '$PDB';" | tr -d '\r') || { PRE_ERR="cannot read $PDB of $PRIMARY_SID"; return 1; }
  [ "$s" = 'READ WRITE' ] || { PRE_ERR="$PDB on $PRIMARY_SID is '$s', not READ WRITE"; return 1; }
  DF_DIR=$(ora_sql "$PRIMARY_SID" <<<"SELECT SUBSTR(d.name, 1, INSTR(d.name, '/', -1) - 1) FROM v\$datafile d JOIN v\$containers c ON c.con_id = d.con_id WHERE c.name = '$PDB' AND d.name LIKE '%/system01.dbf';" | tr -d '[:space:]')
  [[ $DF_DIR =~ ^/[A-Za-z0-9_/.-]+$ ]] || { PRE_ERR="cannot read the datafile directory of $PDB (system01.dbf)"; return 1; }
  DF="$DF_DIR/obenhub_fill01.dbf"
  for s in "$PRIMARY_HOST" "$STANDBY_HOST"; do
    dir_ok "$s" || { PRE_ERR="$DF_DIR does not exist on $s"; return 1; }
    file_absent "$s" || { PRE_ERR="$DF already exists on $s"; return 1; }
    a=$(free_gb "$s")
    [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] || { PRE_ERR="less than 1 GB free (or unreadable) in $DF_DIR on $s: '$a'"; return 1; }
  done
  [ "$(ts_count)" = 0 ] || { PRE_ERR="tablespace $TS already exists in $PDB (not created by this run, not dropped)"; return 1; }
  [ "$(user_count)" = 0 ] || { PRE_ERR="user $OWNER already exists in $PDB (not created by this run, not dropped)"; return 1; }
  b=$(df_known "$PRIMARY_SID"); [ "$b" = 0 ] || { PRE_ERR="$DF is already known to $PRIMARY_SID ($b)"; return 1; }
  b=$(df_known "$STANDBY_SID"); [ "$b" = 0 ] || { PRE_ERR="$DF is already known to $STANDBY_SID ($b)"; return 1; }
  [ "$(vm_query "count(last_over_time(oracledb.tablespace_size.limit{service.instance.id=\"$PRIMARY_SID\",oracle.db.pdb=\"$PDB\"}[2m]))")" -ge 1 ] 2>/dev/null || { PRE_ERR="the oracledb receiver reports no oracledb.tablespace_size.limit with oracle.db.pdb=$PDB for $PRIMARY_SID (lab/oracle/files/otelcol-obs.yaml deployed? lab:oracle:collector)"; return 1; }
  LAG_BEFORE=$(lag_pair)
  log "$PDB datafile directory $DF_DIR; standby_file_management $SFM_P / $SFM_S; lag before (transport apply) $LAG_BEFORE"
}

inject() {
  local out t0 t1
  TRIED=1
  CREATE_AT=$(date +%s)
  in_pdb >/dev/null <<SQL || { FAILS+=("creating $TS, $OWNER or $TBL failed"); return 1; }
CREATE TABLESPACE $TS DATAFILE '$DF' SIZE 20M AUTOEXTEND OFF EXTENT MANAGEMENT LOCAL UNIFORM SIZE 128K;
CREATE USER $OWNER NO AUTHENTICATION QUOTA UNLIMITED ON $TS;
CREATE TABLE $OWNER.$TBL (id NUMBER, pad VARCHAR2(2000)) TABLESPACE $TS PCTFREE 0;
SQL
  log "created $TS (20 MB, no autoextend) and $OWNER.$TBL in $PDB"
  t0=$(date +%s)
  out=$(in_pdb <<SQL
DECLARE
  rows_in NUMBER := 0;
  batch NUMBER := $FILL_BATCH;
  code NUMBER := 0;
  failures NUMBER := 0;
  i NUMBER := 0;
BEGIN
  -- batches of $FILL_BATCH rows until the first failure, then single rows until the second one: the free space left in
  -- the blocks of the allocated extents is used up, so that a fresh insert fails too
  WHILE failures < 2 AND i < $FILL_CAP_ITER LOOP
    i := i + 1;
    BEGIN
      INSERT INTO $OWNER.$TBL SELECT i * 1000 + level, RPAD('x', 2000, 'x') FROM dual CONNECT BY level <= batch;
      rows_in := rows_in + batch;
      COMMIT;
    EXCEPTION WHEN OTHERS THEN
      code := SQLCODE;
      failures := failures + 1;
      batch := 1;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('FILL_RESULT code=' || CASE WHEN failures >= 2 THEN TO_CHAR(code) ELSE 'none' END || ' rows=' || rows_in);
END;
/
SQL
  ) || { FAILS+=("the fill block failed"); return 1; }
  t1=$(date +%s)
  FILL_AT=$t1
  FILL_SECS=$((t1 - t0))
  out=$(grep -m1 '^FILL_RESULT ' <<<"$out")
  FILL_CODE=$(sed -n 's/.* code=\(-\?[0-9a-z]*\).*/\1/p' <<<"$out")
  FILL_ROWS=$(sed -n 's/.* rows=\([0-9]*\).*/\1/p' <<<"$out")
  : "${FILL_ROWS:=null}"
  log "fill: $out in ${FILL_SECS}s"
  case $FILL_CODE in
    -1653 | -1688) ;;
    *) FAILS+=("the fill ended with code '$FILL_CODE', not ORA-01653 or ORA-01688 ($FILL_ROWS rows)"); return 1 ;;
  esac
  out=$(in_pdb <<<"SELECT m.used_space || ' ' || m.tablespace_size || ' ' || t.block_size FROM dba_tablespace_usage_metrics m JOIN dba_tablespaces t ON t.tablespace_name = m.tablespace_name WHERE m.tablespace_name = '$TS';" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  read -r USED_BLOCKS SIZE_BLOCKS BLOCK_SIZE <<<"$out"
  if [[ $USED_BLOCKS =~ ^[0-9]+$ && $SIZE_BLOCKS =~ ^[0-9]+$ && $BLOCK_SIZE =~ ^[0-9]+$ ]]; then
    RATIO=$(awk -v u="$USED_BLOCKS" -v s="$SIZE_BLOCKS" 'BEGIN{printf "%.4f", u / s}')
  else
    USED_BLOCKS=null SIZE_BLOCKS=null BLOCK_SIZE=null RATIO=null
    FAILS+=("cannot read DBA_TABLESPACE_USAGE_METRICS for $TS after the fill: '$out'"); return 1
  fi
  # the table's own view of the same space, as a plausibility check of the ratio
  out=$(in_pdb <<<"SELECT (SELECT SUM(bytes) FROM dba_segments WHERE owner = '$OWNER' AND tablespace_name = '$TS') || ' ' || (SELECT COUNT(*) FROM $OWNER.$TBL) FROM dual;" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  read -r SEG_BYTES ROWS_DB <<<"$out"
  [[ $SEG_BYTES =~ ^[0-9]+$ && $ROWS_DB =~ ^[0-9]+$ ]] || { SEG_BYTES=null ROWS_DB=null; }
  log "after the fill: used $USED_BLOCKS of $SIZE_BLOCKS blocks of $BLOCK_SIZE bytes, ratio $RATIO"
  awk -v r="$RATIO" 'BEGIN{exit !(r >= 0.95)}' || { FAILS+=("ratio $RATIO after the fill is below 0.95: the critical tier cannot fire"); return 1; }
  return 0
}
after_detect() {
  local rc=0 o
  if wait_until 120 "OracleTablespaceUsageHigh critical delivered" severity_seen OracleTablespaceUsageHigh "$PRIMARY_SID" "$T_INJECT" critical; then SEV_CRIT=true
  else FAILS+=("OracleTablespaceUsageHigh was not delivered as critical"); rc=1; fi
  # the create reached the standby by redo apply (the file is known to its control file)
  if wait_until 60 "the datafile known to $STANDBY_SID" stby_known; then STBY_FILE_DURING=1
  else STBY_FILE_DURING=0; FAILS+=("$DF is not known to $STANDBY_SID 60 s after the alert: the create did not reach the standby"); rc=1; fi
  # the consequence the alert is about: a fresh insert from a new session fails
  o=$(in_pdb <<<"INSERT INTO $OWNER.$TBL VALUES (-1, RPAD('x', 2000, 'x'));" 2>&1 | grep -E -o -m1 'ORA-[0-9]+')
  RETRY_CODE=${o:-none}
  log "fresh insert from a new session: $RETRY_CODE"
  case $RETRY_CODE in
    ORA-01653 | ORA-01688) ;;
    *) FAILS+=("a fresh insert from a new session returned '$RETRY_CODE', not ORA-01653 or ORA-01688: the tablespace is not full"); rc=1 ;;
  esac
  LAG_DURING=$(lag_pair)
  return "$rc"
}
revert() {
  local rc=0
  [ -n "$TRIED" ] || return 0
  DROP_AT=$(date +%s)
  retry drop_all || { FAILS+=("dropping $OWNER and $TS in $PDB failed three times: $DF (20 MB) may be left on $PRIMARY_HOST and $STANDBY_HOST"); return 1; }
  wait_until 60 "$TS, $OWNER and the datafile gone on the primary" gone || { FAILS+=("$TS, $OWNER or $DF still present on the primary 60 s after the drop"); rc=1; }
  # a create cut short by Ctrl-C may still be running in the remote sqlplus: look again after a pause, drop again if objects appeared
  sleep 10
  if ! gone; then
    log "objects appeared after the first drop (an interrupted create finished late): dropping again"
    retry drop_all || { FAILS+=("the second drop of $OWNER and $TS in $PDB failed three times: $DF (20 MB) may be left on $PRIMARY_HOST and $STANDBY_HOST"); return 1; }
    wait_until 60 "$TS, $OWNER and the datafile gone on the primary (second drop)" gone || { FAILS+=("$TS, $OWNER or $DF still present on the primary 60 s after the second drop"); rc=1; }
  fi
  PRIM_FILE_AFTER=$(file_absent "$PRIMARY_HOST" && echo absent || echo present)
  log "dropped; datafile on the primary: $PRIM_FILE_AFTER"
  # the drop reaches the standby by redo: switch a log so that it is shipped now
  log_switch || true
  wait_until 180 "the datafile gone on the standby" stby_gone || { FAILS+=("$DF still present or known on $STANDBY_SID 180 s after the drop (redo apply stopped on the missing file operation?)"); rc=1; }
  STBY_FILE_AFTER=$(stby_gone && echo absent || echo present)
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the drop"); rc=1; }
  LAG_AFTER=$(lag_pair)
  return "$rc"
}

extra_checks() {
  local a=$FILL_AT b=$DROP_AT use lim uv lv hb hbs err
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the oracledb receiver (C##OBENHUB_MON, 30 s): the series of the scenario's tablespace
  use=$(series_stats "oracledb.tablespace_size.usage{service.instance.id=\"$PRIMARY_SID\",tablespace_name=\"$TS\",oracle.db.pdb=\"$PDB\"}" "$a" "$b" 30) || use=null
  lim=$(series_stats "oracledb.tablespace_size.limit{service.instance.id=\"$PRIMARY_SID\",tablespace_name=\"$TS\",oracle.db.pdb=\"$PDB\"}" "$a" "$b" 30) || lim=null
  uv=$(series_max "oracledb.tablespace_size.usage{service.instance.id=\"$PRIMARY_SID\",tablespace_name=\"$TS\",oracle.db.pdb=\"$PDB\"}" "$CREATE_AT" "$b") || uv=null
  lv=$(series_max "oracledb.tablespace_size.limit{service.instance.id=\"$PRIMARY_SID\",tablespace_name=\"$TS\",oracle.db.pdb=\"$PDB\"}" "$CREATE_AT" "$b") || lv=null
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "$b" 15) || hbs=null
  err=$(collector_errors "$CREATE_AT" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson c "$CREATE_AT" --argjson a "$a" --argjson b "$b" --argjson use "${use:-null}" --argjson lim "${lim:-null}" \
    --argjson uv "${uv:-null}" --argjson lv "${lv:-null}" --argjson hb "${hb:-null}" --argjson hbs "${hbs:-null}" --argjson err "${err:-null}" \
    --argjson rows "${FILL_ROWS:-null}" --argjson fsecs "${FILL_SECS:-null}" --argjson used "${USED_BLOCKS:-null}" --argjson size "${SIZE_BLOCKS:-null}" \
    --argjson bs "${BLOCK_SIZE:-null}" --argjson seg "${SEG_BYTES:-null}" --argjson rowsdb "${ROWS_DB:-null}" --argjson ratio "${RATIO:-null}" --argjson crit "$SEV_CRIT" \
    --arg pdb "$PDB" --arg ts "$TS" --arg code "$FILL_CODE" --arg retry "$RETRY_CODE" --arg sfm_p "$SFM_P" --arg sfm_s "$SFM_S" \
    --arg sd "$STBY_FILE_DURING" --arg sa "$STBY_FILE_AFTER" --arg pa "$PRIM_FILE_AFTER" \
    --arg l0 "$LAG_BEFORE" --arg l1 "$LAG_DURING" --arg l2 "$LAG_AFTER" \
    '{pdb: $pdb, tablespace: $ts, datafile_mb: 20, autoextend: false, create_epoch: $c, filled_epoch: $a, drop_epoch: $b, full_s: ($b - $a),
      fill: {end_code: $code, rows: $rows, seconds: $fsecs, fresh_insert_after_alert: $retry},
      usage_after_fill: {used_blocks: $used, size_blocks: $size, block_size: $bs, ratio: $ratio, table_segment_bytes: $seg, table_rows: $rowsdb},
      standby_file_management: {primary: $sfm_p, standby: $sfm_s},
      oracledb_receiver: {usage: $use, limit: $lim, usage_values_create_to_drop: $uv, limit_values_create_to_drop: $lv},
      heartbeat_primary: $hb, heartbeat_standby: $hbs, collector_log: $err,
      standby_datafile_known: {after_alert: $sd},
      datafile_after_drop: {primary: $pa, standby: $sa},
      lag_transport_apply_s: {before: $l0, during: $l1, after_drop: $l2}, critical_delivered: $crit}')
  log "extra: $EXTRA_JSON"
}
run_scenario tablespace-full
