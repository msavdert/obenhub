#!/usr/bin/env bash
# Scenario archiver-stuck: the archiver of the CDB19 primary on ora-au-lab cannot write to the local archive destination because the recovery area limit is lowered below what the area holds. The scenario reads DB_RECOVERY_FILE_DEST_SIZE and the space used in the recovery area (V$RECOVERY_FILE_DEST), the bytes of flashback logs (V$FLASHBACK_DATABASE_LOGFILE), and sets DB_RECOVERY_FILE_DEST_SIZE with ALTER SYSTEM ... SCOPE=MEMORY (never the SPFILE, so an instance restart returns the original value) to TARGET = 90% of (space used - reclaimable space - bytes of flashback logs), all three read before the change (V$RECOVERY_FILE_DEST SPACE_USED and SPACE_RECLAIMABLE, V$FLASHBACK_DATABASE_LOGFILE BYTES). Oracle deletes reclaimable files (archived logs that are applied and backed up, flashback logs past retention) when it needs room (unverified: from memory, not read in the documentation; the trials saw nothing deleted with TARGET below that bound), so TARGET must be below what cannot be reclaimed: the pre-flight asserts TARGET < space used - reclaimable space, and at least 1 GiB. Flashback logs are subtracted as well because Oracle may delete them under space pressure even inside the retention target (assumption, not read in the documentation by this scenario); the reclaimable flashback logs are then subtracted twice, which only lowers TARGET. Whether anything was deleted is recorded as the space used, the reclaimable space and the flashback log count and bytes before, during and after. Then one session in the transient systemd unit UNIT on ora-au-lab runs ALTER SYSTEM SWITCH LOGFILE a few times (no redo is needed: an empty log switch archives a few MB, and no table, user or other object is created, which differs from the blocking-session shape on purpose). The first switch makes ARCH try to archive the log that was current and fail with ORA-19809/ORA-19804 (V$ARCHIVE_DEST for destination 1 goes to ERROR, ORA-00257 for non-SYSDBA logins); after all three online groups are unarchived the next switch waits (the kept record shows the third switch waiting in `switch logfile command`); sessions that commit are expected to hang (not tested), sessions that only read do not (a SYSDBA SELECT, dgmgrl and the Collector heartbeat were recorded working).
# Expectation, derived from packs/oracledb-dg/rules.yml and queries.yaml: the sql_query receiver on the primary (C##OBENHUB_DG as SYSDG, 15 s) reports oracledb.archive_dest.valid for every non-INACTIVE destination of V$ARCHIVE_DEST_STATUS that is not TYPE UNKNOWN, the local destination 1 included (it was left out before this scenario); when the archiver cannot write, destination 1 reads ERROR (ORA-19809) and its series is 0 with the status label ERROR. OracleRedoDestinationInvalid fires for CDB19 once that value has been 0 for 1 minute (rule hold), so the alert is about 2 minutes old when delivered, after Alertmanager's grouping; the run reads the delivered notification and requires destination 1 in it (the remote destination 2 would fire the same alert name). The recovery area side is the same fault: oracledb.recovery_area.* (packs/oracledb-backup/queries.yaml, 60 s) shows (usage - reclaimable) / limit above 1, and OracleRecoveryAreaFull would fire after its 10 minute hold; the run ends long before that, so the alert is on the allow list (a known consequence of this fault, not waited for) and the record says whether it was delivered. Any other alert is reported as unexpected. Before the alert is waited for, the scenario reads V$ARCHIVE_DEST for the effect (status ERROR with an ORA code, unarchived online groups) and the alert log (ORA-19809 or ORA-19804 or ORA-00257 since the injection); after the alert it checks the receiver's series for destination 1 and the recovery area limit series (the 60 s receiver must show the lowered limit).
# Guard: besides the shared pre-flight (pair healthy, receivers flowing) the run refuses to start unless CDB19 is the PRIMARY (pre-flight), the broker reports the pair SYNCHRONIZED, the health condition Stuck Archiver of fast-start failover is NO and no Oracle error condition is configured (a stuck archiver would otherwise be a failover trigger; the scenario never touches the condition), destination 1 is VALID with no unarchived online log, the recovery area is configured with a numeric limit and usage, the limit and TARGET are sane (TARGET above 1 GiB and below the limit), the unit does not exist, and the Collector already reports the limit series of CDB19 with the value the database reads and oracledb.archive_dest.valid of destination 1 as VALID (1) for both databases (the query of packs/oracledb-dg is deployed: lab:oracle:collector). The original value and the usage are logged before anything is changed. After the revert the pair is checked healthy and the lag at three points is recorded.
# Revert: from the shared exit trap (also on Ctrl-C and when the inject failed half way), idempotent, three attempts each: stop the unit, then ALTER SYSTEM SET DB_RECOVERY_FILE_DEST_SIZE back to the saved original (SCOPE=MEMORY) and wait until the parameter reads it, then wait for ARCH to resume by itself (destination 1 VALID and every non-current online group archived); when it has not after ARCH_WAIT seconds ALTER SYSTEM ARCHIVE LOG ALL is run and the run records that it was needed; then one log switch with ARCHIVE LOG CURRENT, a late re-check after a pause for a step that finished late, and the pair healthy (lag, no gap). If the restore fails the limit stays at TARGET and the failure reason names the saved original; nothing is ever deleted by hand from the recovery area. If this script is killed (SIGKILL) the original value is in its log line, and the SPFILE still holds it.
# shellcheck disable=SC1091,SC2016,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleRedoDestinationInvalid:$PRIMARY_SID")
# the recovery area alert needs 10 minutes of the same fault; the run is over long before
ALLOW=("OracleRecoveryAreaFull:$PRIMARY_SID")
DETECT_TIMEOUT=420
DETECT_DEADLINE=420
HOLD_AFTER_DETECT=30

UNIT=obenhub-archiver-stuck
SWITCHES=6
UNIT_CAP=1500
ARCH_WAIT=90
MIN_TARGET=1073741824
MB=1048576
ALERT_LOG=/u01/app/oracle/diag/rdbms/cdb19/CDB19/trace/alert_CDB19.log

TRIED="" UNIT_TRIED="" START_AT="" STUCK_AT="" RELEASE_AT="" RESTORED_AT="" ARCH_OK_AT=""
ORA_HOME="" ORIG_LIMIT="" TARGET="" USED0="" RECL0="" FB0="" BASE=""
FRA_BEFORE="" FRA_STUCK="" FRA_DETECT="" FRA_AFTER="" FB_BEFORE="" FB_STUCK="" FB_AFTER="" FBON_BEFORE="" FBON_AFTER=""
STUCK_ROW="" STUCK_ROW2="" STUCK_EVENT="" ALERT_LINES0="" ALERT_CODES=null ALERT_CODES_AFTER=null
SERIES_AT_ALERT=null RATIO_AT_ALERT=null
DEST1_SERIES="" DEST1_VIEW="" ALERT_DEST="" AREA_FULL=""
PROBE_SELECT="" PROBE_MON="" PROBE_DG="" PROBE_SWITCH=""
MANUAL_ARCH=false SWITCH_AFTER=""
LAG_BEFORE="" LAG_DURING="" LAG_AFTER="" GAP_AFTER=""

# the switch loop, run as oracle inside the unit (env: ORACLE_*, N); its output goes to the journal of the unit. The
# switch that cannot get a free group waits, which is the stuck LGWR; the unit is stopped by the revert
read -r -d '' SWITCHER <<'SWITCH_EOF'
for i in $(seq 1 "$N"); do
  printf 'whenever sqlerror continue\nalter system switch logfile;\nexit\n' | sqlplus -s -L '/ as sysdba' 2>&1
  echo "switch $i returned epoch=$(date +%s)"
  sleep 2
done
echo "switch loop ended epoch=$(date +%s)"
SWITCH_EOF

unit_state() { rn "$PRIMARY_HOST" systemctl show -p ActiveState --value "$UNIT"; }
unit_load() { rn "$PRIMARY_HOST" systemctl show -p LoadState --value "$UNIT"; }
unit_down() { case $(unit_state) in inactive | failed) true ;; *) false ;; esac; }
stop_unit() { rn "$PRIMARY_HOST" systemctl stop "$UNIT" >/dev/null 2>&1; unit_down; }
unit_log() { rn "$PRIMARY_HOST" journalctl -u "$UNIT" --since "@$START_AT" -o cat --no-pager 2>/dev/null; }

# fra_snap: "limit used reclaimable files" of V$RECOVERY_FILE_DEST, empty when no recovery area
fra_snap() { ora_sql "$PRIMARY_SID" <<<'SELECT space_limit || CHR(32) || space_used || CHR(32) || space_reclaimable || CHR(32) || number_of_files FROM v$recovery_file_dest;' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
# fb_snap: "files bytes" of the flashback logs
fb_snap() { ora_sql "$PRIMARY_SID" <<<'SELECT COUNT(*) || CHR(32) || NVL(SUM(bytes), 0) FROM v$flashback_database_logfile;' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
flashback_on() { ora_sql "$PRIMARY_SID" <<<'SELECT flashback_on FROM v$database;' | tr -d '[:space:]'; }
# limit_now: the in-memory value of DB_RECOVERY_FILE_DEST_SIZE
limit_now() { ora_sql "$PRIMARY_SID" <<<"SELECT value FROM v\$parameter WHERE name = 'db_recovery_file_dest_size';" | tr -d '[:space:]'; }
set_limit() { ora_sql "$PRIMARY_SID" >/dev/null <<<"ALTER SYSTEM SET db_recovery_file_dest_size = $1 SCOPE=MEMORY;"; }
restore_limit() { set_limit "$ORIG_LIMIT"; }
limit_restored() { [ "$(limit_now)" = "$ORIG_LIMIT" ]; }
# dest1: "status error" of the local archive destination (error text spaces as underscores, - when none)
dest1() {
  ora_sql "$PRIMARY_SID" <<<"SELECT status || ' ' || NVL(REPLACE(SUBSTR(error, 1, 120), ' ', '_'), '-') FROM v\$archive_dest WHERE dest_id = 1;" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}
dest1_valid() { [ "$(dest1)" = 'VALID -' ]; }
# unarchived: online groups that are not current and not archived
unarchived() { ora_sql "$PRIMARY_SID" <<<"SELECT COUNT(*) FROM v\$log WHERE archived = 'NO' AND status <> 'CURRENT';" | tr -d '[:space:]'; }
arch_resumed() { dest1_valid && [ "$(unarchived)" = 0 ]; }
# switch_event: the wait event of a user session in a log file switch wait or in the switch logfile command (the event the first trial of 2026-11-15 saw on the third switch), spaces as underscores
switch_event() {
  ora_sql "$PRIMARY_SID" <<<"SELECT NVL(MAX(REPLACE(event, ' ', '_')), '-') FROM v\$session WHERE type = 'USER' AND (event LIKE 'log file switch%' OR event = 'switch logfile command');" | tr -d '[:space:]'
}
# stuck_now: "<dest1 status> <error> <unarchived groups> <switch wait event>"
stuck_now() { local d u e; d=$(dest1) && u=$(unarchived) && e=$(switch_event) && printf '%s %s %s\n' "$d" "$u" "$e"; }
# stuck_seen: destination 1 is not VALID, its error is an ORA code, and at least one online group is unarchived
stuck_seen() {
  local r; r=$(stuck_now) || return 1
  grep -q -E '^ERROR ORA-' <<<"$r" || return 1
  [ "$(awk '{print $3}' <<<"$r")" -ge 1 ] 2>/dev/null || return 1
  STUCK_ROW=$r
}
# alert log lines of this run: the alert log was ALERT_LINES0 lines long before the injection
alert_codes() {
  rn "$PRIMARY_HOST" tail -n "+$((ALERT_LINES0 + 1))" "$ALERT_LOG" | grep -E -o 'ORA-(19809|19804|19815|00257|16038|00270)' | sort | uniq -c \
    | sed -E 's/^ *([0-9]+) (.*)$/\1\t\2/' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {(.[1]): (.[0] | tonumber)}) | add // {}'
}
# bounded probes: what still works while the archiver is stuck (recorded, not asserted)
probe() { ( REMOTE_TIMEOUT=45; "$@" ) 2>/dev/null; }
probe_select() { probe ora_sql "$PRIMARY_SID" <<<"SELECT 'select-ok' FROM dual;" | tr -d '[:space:]'; }
probe_dg() { probe dg "$PRIMARY_SID" 'show configuration' | grep -E -o '^(SUCCESS|WARNING|ERROR)' | head -n1; }

series_first_positive() {
  curl -fsS "$VM/api/v1/export" --data-urlencode "match[]=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" \
    | jq -s -c '[.[] | [.timestamps, .values] | transpose[] | select(.[1] > 0) | {epoch: (.[0] / 1000 | floor), value: .[1]}] | sort_by(.epoch) | .[0] // null'
}
# alert_starts_at: startsAt of the first firing notification of the expected alert, from VictoriaLogs
alert_starts_at() {
  vl "_time:>$T_INJECT status:=firing commonLabels.alertname:=OracleRedoDestinationInvalid commonLabels.service_instance_id:=$PRIMARY_SID | sort by (_time) | limit 1 | fields alerts" \
    | jq -r '.alerts | fromjson | .[0].startsAt' | head -n1
}
# alert_dest_id: the oracledb.archive_dest.id label (Alertmanager notifications carry it as oracledb_archive_dest_id) inside the first delivered firing notification of the expected alert
alert_dest_id() {
  vl "_time:>$T_INJECT status:=firing commonLabels.alertname:=OracleRedoDestinationInvalid commonLabels.service_instance_id:=$PRIMARY_SID | sort by (_time) | limit 1 | fields alerts" \
    | jq -r '.alerts | fromjson | [.[].labels.oracledb_archive_dest_id] | unique | join(",")' | head -n1
}
# dest1_series INSTANCE: the receiver's oracledb.archive_dest.valid series of destination 1 in the last minute, "<status>=<value>" per series
dest1_series() {
  curl -fsS "$VM/api/v1/query" --data-urlencode "query=last_over_time(oracledb.archive_dest.valid{service.instance.id=\"$1\",oracledb.archive_dest.id=\"1\"}[1m])" \
    | jq -r '[.data.result[] | "\(.metric["oracledb.archive_dest.status"])=\(.value[1])"] | sort | join(",")'
}
# dest1_view: V$ARCHIVE_DEST_STATUS (the view the receiver reads) for destination 1, "type status"
dest1_view() { ora_sql "$PRIMARY_SID" <<<'SELECT type || CHR(32) || status FROM v$archive_dest_status WHERE dest_id = 1;' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
# area_full_delivered: first delivery of OracleRecoveryAreaFull for the primary since the injection, empty when none
area_full_delivered() { first_record firing OracleRecoveryAreaFull "$PRIMARY_SID" "$T_INJECT"; }
# vm_ra NAME INSTANCE: last value of the recovery area series in the last 2 minutes (the receiver of packs/oracledb-backup/queries.yaml collects every 60 s, read from the sample times of 2026-11-15)
vm_ra() { vm_query "max(last_over_time(oracledb.recovery_area.$1{service.instance.id=\"$2\"}[2m]))"; }

# pre-flight of this scenario on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  local s v f
  base_pre || return 1
  sync_ok || { PRE_ERR="the pair is not SYNCHRONIZED (protection level and fast-start failover status)"; return 1; }
  f=$(dg "$PRIMARY_SID" 'show fast_start failover') || { PRE_ERR="cannot read fast-start failover from the broker"; return 1; }
  grep -q -E '^ *Stuck Archiver +NO *$' <<<"$f" || { PRE_ERR="the fast-start failover health condition Stuck Archiver is not NO (a stuck archiver could fail the primary over): $(grep -E 'Stuck Archiver' <<<"$f" | tr -s ' ')"; return 1; }
  grep -A1 'Oracle Error Conditions' <<<"$f" | grep -q '(none)' || { PRE_ERR="fast-start failover has Oracle error conditions configured"; return 1; }
  s=$(dest1) || { PRE_ERR="cannot read V\$ARCHIVE_DEST of $PRIMARY_SID"; return 1; }
  [ "$s" = 'VALID -' ] || { PRE_ERR="local archive destination 1 of $PRIMARY_SID is '$s', not VALID"; return 1; }
  s=$(unarchived) || { PRE_ERR="cannot read V\$LOG of $PRIMARY_SID"; return 1; }
  [ "$s" = 0 ] || { PRE_ERR="$s online groups of $PRIMARY_SID wait for archiving"; return 1; }
  ORIG_LIMIT=$(limit_now)
  [[ $ORIG_LIMIT =~ ^[0-9]+$ ]] || { PRE_ERR="DB_RECOVERY_FILE_DEST_SIZE of $PRIMARY_SID is not a number: '$ORIG_LIMIT'"; return 1; }
  FRA_BEFORE=$(fra_snap)
  read -r v USED0 RECL0 _ <<<"$FRA_BEFORE"
  { [[ $v =~ ^[0-9]+$ ]] && [[ $USED0 =~ ^[0-9]+$ ]] && [[ $RECL0 =~ ^[0-9]+$ ]]; } || { PRE_ERR="no readable recovery area on $PRIMARY_SID: '$FRA_BEFORE'"; return 1; }
  [ "$v" = "$ORIG_LIMIT" ] || { PRE_ERR="V\$RECOVERY_FILE_DEST limit $v differs from DB_RECOVERY_FILE_DEST_SIZE $ORIG_LIMIT"; return 1; }
  FB_BEFORE=$(fb_snap)
  read -r _ f <<<"$FB_BEFORE"
  [[ $f =~ ^[0-9]+$ ]] || { PRE_ERR="cannot read the flashback logs: '$FB_BEFORE'"; return 1; }
  FBON_BEFORE=$(flashback_on)
  FB0=$f
  BASE=$((USED0 - RECL0 - FB0))
  TARGET=$((BASE * 9 / 10 / MB * MB))
  { [ "$TARGET" -ge "$MIN_TARGET" ] && [ "$TARGET" -lt "$((USED0 - RECL0))" ] && [ "$TARGET" -lt "$ORIG_LIMIT" ]; } || { PRE_ERR="the computed limit $TARGET (90% of $BASE = $USED0 used - $RECL0 reclaimable - $FB0 flashback log bytes) is below 1 GiB, or not below the non-reclaimable usage $((USED0 - RECL0)) or the limit $ORIG_LIMIT"; return 1; }
  s=$(unit_load)
  [ -n "$s" ] || { PRE_ERR="cannot read the state of the unit $UNIT on $PRIMARY_HOST (ssh or systemctl failed)"; return 1; }
  [ "$s" = not-found ] || { PRE_ERR="the unit $UNIT already exists on $PRIMARY_HOST (load state $s; stop it first)"; return 1; }
  ORA_HOME=$(rn "$PRIMARY_HOST" awk -F: -v s="$PRIMARY_SID" '$1==s {print $2}' /etc/oratab)
  [[ $ORA_HOME =~ ^/[A-Za-z0-9_/.-]+$ ]] || { PRE_ERR="cannot read ORACLE_HOME of $PRIMARY_SID from /etc/oratab"; return 1; }
  v=$(vm_ra limit "$PRIMARY_SID")
  [ "$v" = "$ORIG_LIMIT" ] || { PRE_ERR="the receiver reports oracledb.recovery_area.limit '${v:-none}' for $PRIMARY_SID, the database reads $ORIG_LIMIT (packs/oracledb-backup/queries.yaml deployed? lab:oracle:collector)"; return 1; }
  for v in "$PRIMARY_SID" "$STANDBY_SID"; do
    [ "$(dest1_series "$v")" = 'VALID=1' ] || { PRE_ERR="the receiver does not report oracledb.archive_dest.valid for destination 1 of $v as VALID=1 (got '$(dest1_series "$v")'; packs/oracledb-dg/queries.yaml deployed? lab:oracle:collector)"; return 1; }
  done
  LAG_BEFORE=$(lag_pair)
  log "ORIGINAL DB_RECOVERY_FILE_DEST_SIZE $ORIG_LIMIT; recovery area (limit used reclaimable files) $FRA_BEFORE; flashback logs (files bytes) $FB_BEFORE, flashback $FBON_BEFORE; target $TARGET; ORACLE_HOME $ORA_HOME; lag before (transport apply) $LAG_BEFORE"
}

inject() {
  TRIED=1
  ALERT_LINES0=$(rn "$PRIMARY_HOST" wc -l "$ALERT_LOG" | awk '{print $1}')
  [[ $ALERT_LINES0 =~ ^[0-9]+$ ]] || { FAILS+=("cannot count the lines of the alert log $ALERT_LOG"); return 1; }
  set_limit "$TARGET" || { FAILS+=("ALTER SYSTEM SET db_recovery_file_dest_size = $TARGET failed"); return 1; }
  log "DB_RECOVERY_FILE_DEST_SIZE set to $TARGET (SCOPE=MEMORY); now $(limit_now)"
  UNIT_TRIED=1
  START_AT=$(date +%s)
  rn "$PRIMARY_HOST" systemd-run --unit="$UNIT" --collect --quiet --uid=oracle \
    --property=MemoryMax=1G --property=TasksMax=100 --property=CPUWeight=20 --property=RuntimeMaxSec="$UNIT_CAP" \
    --setenv=ORACLE_SID="$PRIMARY_SID" --setenv=ORACLE_HOME="$ORA_HOME" --setenv=PATH="$ORA_HOME/bin:/usr/bin:/bin" --setenv=N="$SWITCHES" \
    bash -c "$SWITCHER" || { FAILS+=("systemd-run of the switch unit failed"); return 1; }
  if ! wait_until 240 "the archiver stuck (destination 1 in ERROR, unarchived online groups)" stuck_seen; then
    FAILS+=("the archiver did not get stuck within 240 s: destination 1 '$(dest1)', unarchived $(unarchived); unit journal: $(unit_log | tail -n 6 | tr '\n' '|')")
    return 1
  fi
  STUCK_AT=$(date +%s)
  STUCK_EVENT=$(switch_event)
  FRA_STUCK=$(fra_snap); FB_STUCK=$(fb_snap)
  log "stuck: destination 1 / error / unarchived groups / switch wait: $STUCK_ROW; recovery area $FRA_STUCK; flashback logs $FB_STUCK"
  return 0
}
after_detect() {
  local rc=0 s u l r
  STUCK_ROW2=$(stuck_now) || STUCK_ROW2=""
  log "after the alert: $STUCK_ROW2"
  grep -q -E '^ERROR ORA-' <<<"$STUCK_ROW2" || { FAILS+=("after the alert destination 1 is not in ERROR: '$STUCK_ROW2'"); rc=1; }
  FRA_DETECT=$(fra_snap)
  ALERT_CODES=$(alert_codes) || ALERT_CODES=null
  jq -e 'has("ORA-19809") or has("ORA-19804") or has("ORA-00257")' >/dev/null <<<"${ALERT_CODES:-null}" || { FAILS+=("the alert log shows no ORA-19809, ORA-19804 or ORA-00257 since the injection: $ALERT_CODES"); rc=1; }
  # the series the rule reads (an instant query ignores the newest 30 s by default, see blocking-session.sh)
  l=$(vm_ra limit "$PRIMARY_SID"); u=$(vm_ra usage "$PRIMARY_SID"); r=$(vm_ra reclaimable "$PRIMARY_SID")
  SERIES_AT_ALERT=$(jq -n -c --arg l "${l:-}" --arg u "${u:-}" --arg r "${r:-}" '{limit: ($l | tonumber? // null), usage: ($u | tonumber? // null), reclaimable: ($r | tonumber? // null)}')
  if [ -n "$l" ] && [ -n "$u" ] && [ -n "$r" ]; then
    RATIO_AT_ALERT=$(awk -v l="$l" -v u="$u" -v r="$r" 'BEGIN{ if (l > 0) printf "%.3f", (u - r) / l; else print "null" }')
  else
    RATIO_AT_ALERT=null
  fi
  log "recovery area series at the alert: $SERIES_AT_ALERT, (usage - reclaimable) / limit = $RATIO_AT_ALERT"
  [ "$l" = "$TARGET" ] || { FAILS+=("the receiver reports limit '${l:-none}' after the alert, not $TARGET"); rc=1; }
  awk -v x="$RATIO_AT_ALERT" 'BEGIN{exit !(x != "null" && x > 0.85)}' || { FAILS+=("(usage - reclaimable) / limit is '$RATIO_AT_ALERT' after the alert, not above 0.85"); rc=1; }
  ALERT_DEST=$(alert_dest_id) || ALERT_DEST=""
  DEST1_VIEW=$(dest1_view) || DEST1_VIEW=""
  DEST1_SERIES=$(dest1_series "$PRIMARY_SID") || DEST1_SERIES=""
  log "delivered alert names destination id '${ALERT_DEST:-none}'; V\$ARCHIVE_DEST_STATUS destination 1: '$DEST1_VIEW'; receiver series (status=value): '$DEST1_SERIES'"
  [ "$ALERT_DEST" = 1 ] || { FAILS+=("the delivered OracleRedoDestinationInvalid names destination '${ALERT_DEST:-none}', not the local destination 1"); rc=1; }
  grep -q '^LOCAL ERROR$' <<<"$DEST1_VIEW" || { FAILS+=("V\$ARCHIVE_DEST_STATUS destination 1 reads '$DEST1_VIEW', not LOCAL ERROR"); rc=1; }
  grep -q 'ERROR=0' <<<"$DEST1_SERIES" || { FAILS+=("the receiver has no ERROR=0 series for destination 1 of $PRIMARY_SID: '$DEST1_SERIES'"); rc=1; }
  # what works while the archiver is stuck (recorded, not asserted)
  PROBE_SELECT=$(probe_select); PROBE_DG=$(probe_dg)
  pw_ok && PROBE_MON=$(probe mon_login full) || PROBE_MON=""
  PROBE_SWITCH=$(unit_log | grep -c 'returned epoch=' || true)
  log "probes while stuck: sysdba select '${PROBE_SELECT:-none}', dgmgrl show configuration '${PROBE_DG:-none}', fresh $MON_USER login '${PROBE_MON:-not run}', switches returned $PROBE_SWITCH of $SWITCHES"
  LAG_DURING=$(lag_pair)
  return "$rc"
}
# resume_archiver: with the limit restored, wait for ARCH to resume by itself, else ALTER SYSTEM ARCHIVE LOG ALL (recorded in MANUAL_ARCH)
resume_archiver() {
  limit_restored || { log "limit is not restored, archiver wait skipped"; return 1; }
  arch_resumed && return 0
  if ! wait_until "$ARCH_WAIT" "ARCH resumed (destination 1 VALID, no unarchived online group)" arch_resumed; then
    log "ARCH did not resume by itself in ${ARCH_WAIT}s ($(stuck_now)): ALTER SYSTEM ARCHIVE LOG ALL"
    MANUAL_ARCH=true
    ora_sql "$PRIMARY_SID" <<<'ALTER SYSTEM ARCHIVE LOG ALL;' >/dev/null || true
    wait_until 120 "ARCH resumed after ARCHIVE LOG ALL" arch_resumed || { FAILS+=("ARCH did not resume: $(stuck_now)"); return 1; }
  fi
}
revert() {
  local rc=0
  [ -n "$TRIED" ] || return 0
  RELEASE_AT=$(date +%s)
  # the switch unit first (it may hold a session that waits for archiving), then the limit; a failed step is recorded and the rest still runs
  retry stop_unit || { FAILS+=("systemctl stop $UNIT failed three times: the unit ends by itself $UNIT_CAP s after its start"); rc=1; }
  if retry restore_limit; then
    wait_until 60 "DB_RECOVERY_FILE_DEST_SIZE back to $ORIG_LIMIT" limit_restored || { FAILS+=("DB_RECOVERY_FILE_DEST_SIZE reads '$(limit_now)' 60 s after the restore, not $ORIG_LIMIT"); rc=1; }
    RESTORED_AT=$(date +%s)
    log "limit restored: $(limit_now)"
  else
    FAILS+=("restoring DB_RECOVERY_FILE_DEST_SIZE to $ORIG_LIMIT failed three times: the limit stays at $TARGET until the late re-check (SCOPE=MEMORY; the SPFILE still holds the original)")
    rc=1
  fi
  resume_archiver || rc=1
  ARCH_OK_AT=$(date +%s)
  log "archiver step done ${ARCH_OK_AT} (restore at ${RESTORED_AT:-none}): $(stuck_now)"
  # a log switch must succeed again, but only once the limit is back: with the limit still lowered it would block (up to the remote timeout per attempt) before the late re-check below retries the restore
  if ! limit_restored; then SWITCH_AFTER=skipped; FAILS+=("no log switch after the restore: the limit is not restored yet"); rc=1
  elif retry log_switch; then SWITCH_AFTER=ok; else SWITCH_AFTER=failed; FAILS+=("a log switch (ARCHIVE LOG CURRENT) failed three times after the restore"); rc=1; fi
  # a restore or a unit start cut short by Ctrl-C may still be running remotely: look again after a pause
  sleep 10
  if ! { limit_restored && unit_down; }; then
    log "limit or unit not as expected after the first pass (an interrupted step finished late, or a step failed): restoring and stopping again"
    retry stop_unit || { FAILS+=("the second stop of $UNIT failed three times"); rc=1; }
    if retry restore_limit; then
      wait_until 60 "DB_RECOVERY_FILE_DEST_SIZE back to $ORIG_LIMIT (second restore)" limit_restored || { FAILS+=("limit still not $ORIG_LIMIT after the second restore"); rc=1; }
      [ -n "$RESTORED_AT" ] || RESTORED_AT=$(date +%s)
    else
      FAILS+=("the second restore of DB_RECOVERY_FILE_DEST_SIZE to $ORIG_LIMIT failed three times: the limit stays at $(limit_now)")
      rc=1
    fi
    resume_archiver || rc=1
  fi
  FRA_AFTER=$(fra_snap); FB_AFTER=$(fb_snap); FBON_AFTER=$(flashback_on)
  ALERT_CODES_AFTER=$(alert_codes) || ALERT_CODES_AFTER=null
  [ "$FBON_AFTER" = "$FBON_BEFORE" ] || { FAILS+=("FLASHBACK_ON of $PRIMARY_SID is '$FBON_AFTER' after the run, was '$FBON_BEFORE' (not changed back by this scenario)"); rc=1; }
  log "restored: limit $(limit_now), recovery area $FRA_AFTER, flashback logs $FB_AFTER, flashback $FBON_AFTER, unit $(unit_state)"
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the restore"); rc=1; }
  GAP_AFTER=$(ora_sql "$STANDBY_SID" <<<'SELECT NVL(SUM(high_sequence# - low_sequence# + 1), 0) FROM v$archive_gap;' | tr -d '[:space:]') || GAP_AFTER=""
  LAG_AFTER=$(lag_pair)
  [ "$GAP_AFTER" = 0 ] || { FAILS+=("the standby reports a gap of '${GAP_AFTER:-unknown}' logs after the restore"); rc=1; }
  return "$rc"
}

extra_checks() {
  local a=$START_AT b=$RELEASE_AT lim use rec hold hb hbs err starts starts_s=null delivered_s=null base after
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the series the rule reads, over the fault, before it and after the restore
  lim=$(series_max "oracledb.recovery_area.limit{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || lim=null
  use=$(series_max "oracledb.recovery_area.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || use=null
  rec=$(series_max "oracledb.recovery_area.reclaimable{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b") || rec=null
  base=$(series_max "oracledb.recovery_area.limit{service.instance.id=\"$PRIMARY_SID\"}" "$((a - 120))" "$a") || base=null
  after=$(series_max "oracledb.recovery_area.limit{service.instance.id=\"$PRIMARY_SID\"}" "$((${RESTORED_AT:-$b} + 45))" "$(date +%s)") || after=null
  hold=$(series_stats "oracledb.recovery_area.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 60) || hold=null
  starts=$(alert_starts_at) || starts=""
  AREA_FULL=$(area_full_delivered) || AREA_FULL=""
  if [ -n "$starts" ] && [ "$starts" != null ]; then
    starts_s=$(date -u -d "$starts" +%s) || starts_s=null
    [ -z "$T_DETECT" ] || delivered_s=$(awk -v a="$(epoch "$starts")" -v b="$(epoch "$T_DETECT")" 'BEGIN{printf "%.1f", b - a}')
  fi
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  hbs=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$STANDBY_SID\"}" "$a" "$b" 15) || hbs=null
  err=$(collector_errors "$a" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson a "$a" --argjson k "${STUCK_AT:-null}" --argjson b "$b" --argjson rs "${RESTORED_AT:-null}" --argjson ar "${ARCH_OK_AT:-null}" \
    --argjson orig "$ORIG_LIMIT" --argjson target "$TARGET" --argjson tbase "$BASE" --argjson nonrecl "$((USED0 - RECL0))" --argjson manual "$MANUAL_ARCH" \
    --argjson lim "${lim:-null}" --argjson use "${use:-null}" --argjson rec "${rec:-null}" --argjson base "${base:-null}" --argjson after "${after:-null}" --argjson hold "${hold:-null}" \
    --argjson sa "${SERIES_AT_ALERT:-null}" --argjson ratio "${RATIO_AT_ALERT:-null}" --argjson codes "${ALERT_CODES:-null}" --argjson codes_after "${ALERT_CODES_AFTER:-null}" \
    --argjson starts_s "$starts_s" --argjson delivered_s "$delivered_s" --argjson hb "${hb:-null}" --argjson hbs "${hbs:-null}" --argjson err "${err:-null}" \
    --arg fra0 "$FRA_BEFORE" --arg fra1 "$FRA_STUCK" --arg fra2 "$FRA_DETECT" --arg fra3 "$FRA_AFTER" --arg fb0 "$FB_BEFORE" --arg fb1 "$FB_STUCK" --arg fb2 "$FB_AFTER" \
    --arg fbon0 "$FBON_BEFORE" --arg fbon1 "$FBON_AFTER" --arg st1 "$STUCK_ROW" --arg st2 "$STUCK_ROW2" --arg ev "$STUCK_EVENT" \
    --arg psel "$PROBE_SELECT" --arg pmon "$PROBE_MON" --arg pdg "$PROBE_DG" --arg psw "$PROBE_SWITCH" --arg swa "$SWITCH_AFTER" --arg gap "$GAP_AFTER" \
    --arg dd "$ALERT_DEST" --arg dv "$DEST1_VIEW" --arg ds "$DEST1_SERIES" --arg af "$AREA_FULL" --arg l0 "$LAG_BEFORE" --arg l1 "$LAG_DURING" --arg l2 "$LAG_AFTER" \
    '{original_limit_bytes: $orig, target_limit_bytes: $target, target_base_bytes: $tbase, non_reclaimable_bytes: $nonrecl, start_epoch: $a, stuck_epoch: $k, release_epoch: $b, restored_epoch: $rs, arch_resumed_epoch: $ar,
      limit_lowered_s: ($b - $a), arch_needed_archive_log_all: $manual,
      recovery_area_limit_used_reclaimable_files: {before: $fra0, stuck: $fra1, at_alert: $fra2, after_restore: $fra3},
      flashback_logs_files_bytes: {before: $fb0, stuck: $fb1, after_restore: $fb2}, flashback_on: {before: $fbon0, after: $fbon1},
      archive_dest1_unarchived_switch_event: {first_reading: $st1, after_alert: $st2, switch_wait_event: $ev},
      alert_log_codes: {at_alert: $codes, after_restore: $codes_after},
      probes_while_stuck: {sysdba_select: $psel, dgmgrl_show_configuration: $pdg, mon_login: $pmon, switches_returned: $psw},
      log_switch_after_restore: $swa, standby_gap_logs_after: $gap,
      oracle_recovery_area: {limit_hold: $lim, usage_hold: $use, reclaimable_hold: $rec, usage_series_hold: $hold, limit_before_start_120s: $base, limit_after_restore: $after, at_alert: $sa, ratio_at_alert: $ratio},
      redo_destination_alert: {destination_id_in_notification: $dd, archive_dest_status_view_dest1: $dv, receiver_series_dest1_status_value: $ds},
      recovery_area_full_delivered: (if $af == "" then false else true end),
      alert: {starts_at_epoch: $starts_s, starts_to_delivered_s: $delivered_s, stuck_to_starts_s: (if $starts_s != null and $k != null then $starts_s - $k else null end)},
      heartbeat_primary: $hb, heartbeat_standby: $hbs, collector_log: $err,
      lag_transport_apply_s: {before: $l0, during: $l1, after_restore: $l2}}')
  log "extra: $EXTRA_JSON"
}
run_scenario archiver-stuck
