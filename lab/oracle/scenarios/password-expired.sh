#!/usr/bin/env bash
# Scenario password-expired: the password of the oracledb receiver's account C##OBENHUB_MON is expired on the CDB19 primary (ALTER USER ... PASSWORD EXPIRE CONTAINER=ALL from the CDB root, as sysdba with OS authentication). The profile of the account has no password life time (lab/oracle/scripts/provision.sh), so only this statement can expire it. The account is a common user: the statement changes it in every container, and the standby gets it through redo. That the standby applied it is not checked: a mounted standby cannot read DBA_USERS (ORA-01219, recorded in extra), so the standby is assumed to follow.
# Expectation, derived from packs/oracledb-dg/rules.yml and queries-primary.yaml: the account status becomes EXPIRED, the sql_query/primary_account receiver on ora-dg-obs (the pooled session of C##OBENHUB_DG, a different account) reads it from DBA_USERS every 15 s and records oracledb.user.open 0 with oracledb.user.status EXPIRED, so OracleMonitoringAccountNotOpen (hold 1m) fires for CDB19. The pair is not affected: nothing else is expected, and any other alert is reported as unexpected.
# Evidence for the planned upstream proposal (ADR 0008 decision 7: pooled sessions hide a changed account): the oracledb receiver (C##OBENHUB_MON, 30 s) holds a pooled session that was opened before the expiry. The record's extra field holds, for the window from the ALTER USER to the restore, the samples of its series (oracledb.sessions.usage, processes.usage, cpu_time), of the sql_query heartbeat and of the new oracledb.user.open series (status EXPIRED) from VictoriaMetrics, the V$SESSION count and newest logon age of the account at the expiry and at the end of the detection (a session that is reused keeps its logon time, so the age grows by the time between the two reads), the error codes the Collector logged (journald on ora-dg-obs; codes and counts only, no log text), and the result of a fresh login attempt as C##OBENHUB_MON from ora-dg-obs right after the expiry and after the alert (the ORA code only; ORA-28001 is expected). SQL*Plus answers ORA-28001 with a prompt for a new password that it reads from stdin, so the attempt sends the connect line and nothing else: the end of input ends the prompt.
# The Collector is not restarted, the pools of the receivers are not touched; whether the receivers survive a restart or a dropped session is not tested here.
# Guard: none beyond the pre-flight. The pre-flight (shared with every Oracle scenario) refuses to start unless the pair is healthy (broker SUCCESS, observer, apply, lag), both accounts are OPEN, a fresh login as C##OBENHUB_MON works with the password in lab/oracle/.env (so that file equals what the database holds, which the restore relies on) and the receivers' series flow. An expired monitoring account affects nothing else on the pair.
# Revert: ALTER USER ... IDENTIFIED BY with the password of lab/oracle/.env (the mechanism of provision.sh --reset-passwords: the value reaches sqlplus on stdin only, never a command line, a file written by this script, a log or the result), ACCOUNT UNLOCK, three attempts, always run from the shared exit trap (also on Ctrl-C and when the injection failed half way: restoring is idempotent); then wait until the status is OPEN and a fresh login works. If it cannot be restored, run lab/oracle/scripts/provision.sh --reset-passwords.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("OracleMonitoringAccountNotOpen:$PRIMARY_SID")
ALLOW=()
DETECT_DEADLINE=240
HOLD_AFTER_DETECT=45

EXPIRE_AT="" RESTORE_AT=""
LOGIN_INJECT="" LOGIN_DURING="" LOGIN_AFTER=""
SESS_EXPIRE="null" SESS_DURING="null"
STATUS_BEFORE="" STATUS_DURING="" STATUS_AFTER="" STBY_READ=""

# acct_status USER: ACCOUNT_STATUS from the root's DBA_USERS on the primary
acct_status() { ora_sql "$PRIMARY_SID" <<<"SELECT account_status FROM dba_users WHERE username = '$1';"; }
# accounts_state: "MON=<status> DG=<status>"
accounts_state() {
  local m d
  m=$(acct_status "$MON_USER") && d=$(acct_status "$DG_USER") && [ -n "$m" ] && [ -n "$d" ] || return 1
  echo "MON=$m DG=$d"
}
mon_open() { [ "$(acct_status "$MON_USER")" = OPEN ]; }
# sess_json: session count and newest logon age (seconds) of the account on the
# primary, with the read time, as JSON
sess_json() {
  local r
  r=$(ora_sql "$PRIMARY_SID" <<<"SELECT COUNT(*) || ' ' || NVL(ROUND((SYSDATE - MAX(logon_time)) * 86400), -1) FROM v\$session WHERE username = '$MON_USER';") || { echo null; return 0; }
  jq -n -c --argjson t "$(date +%s)" --arg r "$r" '($r | split(" ") | map(tonumber? // null)) as $a | {epoch: $t, count: $a[0], newest_logon_age_s: $a[1]}'
}
restore_account() {
  pw_ok || return 1
  printf 'ALTER USER "%s" IDENTIFIED BY "%s" ACCOUNT UNLOCK CONTAINER=ALL;\n' "$MON_USER" "$(mon_pw)" | ora_sql "$PRIMARY_SID" >/dev/null
}

# pre-flight of this scenario on top of the adapter's
eval "$(declare -f lab_precondition | sed '1s/^lab_precondition/base_pre/')"
lab_precondition() {
  base_pre || return 1
  if ! { [ -r "$LAB_DIR/.env" ] && pw_ok; }; then
    PRE_ERR="lab/oracle/.env is missing or ORA_MON_PASSWORD is not 30 hex characters (the restore needs it)"
    return 1
  fi
  STATUS_BEFORE=$(accounts_state) || { PRE_ERR="cannot read the account status"; return 1; }
  [ "$STATUS_BEFORE" = 'MON=OPEN DG=OPEN' ] || { PRE_ERR="accounts are not both OPEN before the expiry: $STATUS_BEFORE"; return 1; }
  [ "$(mon_login full)" = ok ] || { PRE_ERR="a fresh login as $MON_USER fails before the expiry (the password in lab/oracle/.env differs from the database's?)"; return 1; }
  [ "$(vm_query 'count(last_over_time(oracledb.user.open{oracledb.user.status="OPEN"}[30s]) == 1)')" = 2 ] || { PRE_ERR="VictoriaMetrics does not hold oracledb.user.open 1 for both accounts (queries-primary.yaml deployed? lab:oracle:collector)"; return 1; }
  [ "$(vm_query "count(last_over_time(oracledb.sessions.usage{service.instance.id=\"$PRIMARY_SID\"}[1m]))")" -ge 1 ] 2>/dev/null || { PRE_ERR="the oracledb receiver reports no oracledb.sessions.usage for $PRIMARY_SID"; return 1; }
  log "accounts before: $STATUS_BEFORE; sessions of $MON_USER: $(sess_json)"
}

inject() {
  # set before the statement: a statement that failed half way (dropped ssh) is restored too
  EXPIRE_AT=$(date +%s)
  ora_sql "$PRIMARY_SID" <<<"ALTER USER \"$MON_USER\" PASSWORD EXPIRE CONTAINER=ALL;" >/dev/null || { FAILS+=("ALTER USER PASSWORD EXPIRE failed"); return 1; }
  STATUS_DURING=$(accounts_state) || STATUS_DURING=unreadable
  log "accounts after the expiry: $STATUS_DURING"
  [ "$STATUS_DURING" = 'MON=EXPIRED DG=OPEN' ] || { FAILS+=("accounts after PASSWORD EXPIRE: $STATUS_DURING"); return 1; }
  SESS_EXPIRE=$(sess_json)
  LOGIN_INJECT=$(mon_login connect)
  log "fresh login right after the expiry: $LOGIN_INJECT; sessions of $MON_USER: $SESS_EXPIRE"
  [ "$LOGIN_INJECT" = ORA-28001 ] || FAILS+=("fresh login right after the expiry returned $LOGIN_INJECT, not ORA-28001")
  return 0
}
after_detect() {
  STATUS_DURING=$(accounts_state) || STATUS_DURING=unreadable
  SESS_DURING=$(sess_json)
  LOGIN_DURING=$(mon_login connect)
  STBY_READ=$(ora_sql "$STANDBY_SID" <<<"SELECT account_status FROM dba_users WHERE username = '$MON_USER';" 2>&1 | grep -o -m1 'ORA-[0-9]*')
  STBY_READ=${STBY_READ:-none}
  log "after the alert: accounts $STATUS_DURING; fresh login $LOGIN_DURING; sessions $SESS_DURING; standby read $STBY_READ"
  [ "$LOGIN_DURING" = ORA-28001 ] || FAILS+=("fresh login after the alert returned $LOGIN_DURING, not ORA-28001")
  return 0
}
revert() {
  local rc=0
  # nothing was attempted (inject refused before the statement)
  [ -n "$EXPIRE_AT" ] || return 0
  retry restore_account || { FAILS+=("restoring the password failed three times: $MON_USER may be left expired (lab/oracle/scripts/provision.sh --reset-passwords)"); return 1; }
  RESTORE_AT=$(date +%s)
  log "password restored"
  wait_until 60 "$MON_USER OPEN" mon_open || { FAILS+=("$MON_USER is not OPEN 60 s after the restore"); rc=1; }
  STATUS_AFTER=$(accounts_state) || STATUS_AFTER=unreadable
  # only with the account OPEN: see mon_login
  if [ "$STATUS_AFTER" = 'MON=OPEN DG=OPEN' ]; then
    LOGIN_AFTER=$(mon_login full)
    [ "$LOGIN_AFTER" = ok ] || { FAILS+=("fresh login after the restore returned $LOGIN_AFTER"); rc=1; }
  else
    FAILS+=("accounts after the restore: $STATUS_AFTER"); rc=1
  fi
  wait_until 300 "pair healthy" healthy_pair || { FAILS+=("pair not healthy after the restore"); rc=1; }
  return "$rc"
}

extra_checks() {
  local a=$EXPIRE_AT b=$RESTORE_AT sess proc cpu hb open err
  [ -n "$a" ] && [ -n "$b" ] || return 0
  # the oracledb receiver (C##OBENHUB_MON, 30 s)
  sess=$(series_stats "oracledb.sessions.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || sess=null
  proc=$(series_stats "oracledb.processes.usage{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || proc=null
  cpu=$(series_stats "oracledb.cpu_time{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 30) || cpu=null
  # the sql_query heartbeat and the account series (C##OBENHUB_DG as SYSDG, 15 s)
  hb=$(series_stats "oracledb.collection.heartbeat{service.instance.id=\"$PRIMARY_SID\"}" "$a" "$b" 15) || hb=null
  open=$(series_stats "oracledb.user.open{service.instance.id=\"$PRIMARY_SID\",oracledb.user.name=\"$MON_USER\",oracledb.user.status=\"EXPIRED\"}" "$a" "$b" 15) || open=null
  err=$(collector_errors "$a" "$b") || err=null
  EXTRA_JSON=$(jq -n -c --argjson a "$a" --argjson b "$b" --argjson sess "${sess:-null}" --argjson proc "${proc:-null}" --argjson cpu "${cpu:-null}" \
    --argjson hb "${hb:-null}" --argjson open "${open:-null}" --argjson err "${err:-null}" \
    --argjson s1 "${SESS_EXPIRE:-null}" --argjson s2 "${SESS_DURING:-null}" \
    --arg l1 "$LOGIN_INJECT" --arg l2 "$LOGIN_DURING" --arg l3 "$LOGIN_AFTER" \
    --arg st0 "$STATUS_BEFORE" --arg st1 "$STATUS_DURING" --arg st2 "$STATUS_AFTER" --arg stby "$STBY_READ" \
    '{expire_epoch: $a, restore_epoch: $b, expired_s: ($b - $a),
      oracledb_receiver: {sessions_usage: $sess, processes_usage: $proc, cpu_time: $cpu},
      heartbeat_primary: $hb, user_open_expired_series: $open, collector_log: $err,
      sessions_of_account: {at_expiry: $s1, after_alert: $s2},
      fresh_login: {right_after_expiry: $l1, after_alert: $l2, after_restore: $l3},
      accounts: {before: $st0, expired: $st1, after_restore: $st2},
      standby_dba_users_read: $stby}')
  log "extra: $EXTRA_JSON"
}
run_scenario password-expired
