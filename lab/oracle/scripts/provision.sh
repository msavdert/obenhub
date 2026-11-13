#!/usr/bin/env bash
# Provision the monitoring side of the CDB19 Data Guard pair (lab/oracle/pair.sh)
# from this box over ssh, ADR 0008 decision 4:
#   - profile C##OBENHUB_MON whose passwords never expire (ORA-28001);
#   - C##OBENHUB_MON, the oracledb receiver's user: CREATE SESSION, SELECT on
#     the views the receiver README (contrib v0.164.0) lists for its metrics
#     and per-PDB metrics, CONTAINER_DATA=ALL; no role, no SELECT ANY;
#   - C##OBENHUB_DG, the sql_query user of the oracledb-dg pack: SYSDG only;
#   - the primary's password file copied to the standby when they differ
#     (a SYSDG login is checked against the password file);
#   - a login check from the observer VM: both users, both databases.
# Usage: provision.sh [--reset-passwords]
# Users and grants are created on the primary and reach the standby by redo.
# Idempotent: an existing user keeps its password unless --reset-passwords
# is given (setting it again rewrites the password file); the password file is
# copied only when the checksums differ, after a timestamped backup on the
# standby. Passwords come from lab/oracle/.env (gen-env.sh, run here on
# every call; it adds missing keys and keeps values) and reach sqlplus on stdin only. gen-env.sh writes 32 hex
# characters; Oracle allows 30 (ORA-00972), so the first 30 are the password,
# here and in the Collector configuration.
# Assumes: ssh aliases as in pair.sh, user with passwordless sudo, the oracle
# OS user owns the homes, /etc/oratab lists each SID, the pair is up.
# shellcheck disable=SC2029  # remote command lines are built here on purpose
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/pair.sh"

reset=0
case "${1:-}" in
  --reset-passwords) reset=1 ;;
  "") ;;
  *) echo "usage: provision.sh [--reset-passwords]" >&2; exit 2 ;;
esac

# gen-env.sh keeps existing values and adds missing keys
"$dir/../scripts/gen-env.sh" "$dir/.env" ORA_MON_PASSWORD ORA_DG_PASSWORD
set -a
# shellcheck source=/dev/null
. "$dir/.env"
set +a
MON_PW=${ORA_MON_PASSWORD:0:30}
DG_PW=${ORA_DG_PASSWORD:0:30}
for pw in "$MON_PW" "$DG_PW"; do
  # hex only: the value is embedded in SQL and in a data source URL unquoted
  case "$pw" in *[!0-9a-f]*|"") echo "provision: passwords in .env must be hex (gen-env.sh)" >&2; exit 1 ;; esac
  [ "${#pw}" -eq 30 ] || { echo "provision: passwords in .env must have at least 30 characters" >&2; exit 1; }
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
log() { echo "[$1] $2"; }

# oh <host> <sid>: the Oracle home of a SID from /etc/oratab
oh() { ssh -n "${SSH_OPTS[@]}" "$1" "awk -F: -v s='$2' '\$1==s {print \$2}' /etc/oratab"; }

# sysdba <host> <sid> < sql: run SQL as SYSDBA through the local bequeath
sysdba() {
  local home; home="$(oh "$1" "$2")"
  [ -n "$home" ] || { echo "provision: $2 not in /etc/oratab on $1" >&2; return 1; }
  ssh "${SSH_OPTS[@]}" "$1" "sudo -u oracle env ORACLE_SID=$2 ORACLE_HOME=$home $home/bin/sqlplus -s -L / as sysdba"
}

# --- users, profile and grants on the primary --------------------------------
# The views follow the oracledb receiver README at contrib v0.164.0: instance
# detection, metrics and per-PDB metrics (CONTAINER=ALL). ASM, the events
# (query samples, top queries) and the PDB-connection views are left out:
# the lab has no ASM, runs no events and connects to the root.
MON_VIEWS="V_\$INSTANCE V_\$DATABASE V_\$DATAFILE V_\$SESSION V_\$SYSSTAT V_\$RESOURCE_LIMIT
V_\$OSSTAT V_\$SGAINFO V_\$CON_SYSSTAT V_\$CON_SYSMETRIC V_\$CONTAINERS
DBA_TABLESPACES DBA_DATA_FILES DBA_TABLESPACE_USAGE_METRICS
CDB_TABLESPACE_USAGE_METRICS CDB_TABLESPACES CDB_DATA_FILES"
grants=""
for v in $MON_VIEWS; do
  grants="$grants  x('GRANT SELECT ON SYS.$v TO \"$MON_USER\" CONTAINER=ALL');
"
done

log "$PRIMARY_HOST" "profile, users and grants on $PRIMARY_SID"
sysdba "$PRIMARY_HOST" "$PRIMARY_SID" <<SQL
whenever sqlerror exit failure
set feedback off verify off define off serveroutput on
DECLARE
  n NUMBER;
  PROCEDURE x(s VARCHAR2) IS BEGIN EXECUTE IMMEDIATE s; END;
  PROCEDURE ensure_user(u VARCHAR2, pw VARCHAR2) IS
  BEGIN
    SELECT COUNT(*) INTO n FROM dba_users WHERE username = u;
    IF n = 0 THEN
      x('CREATE USER "' || u || '" IDENTIFIED BY "' || pw || '" PROFILE "$MON_PROFILE" ACCOUNT UNLOCK CONTAINER=ALL');
      dbms_output.put_line('created user ' || u);
    ELSIF $reset = 1 THEN
      x('ALTER USER "' || u || '" IDENTIFIED BY "' || pw || '" ACCOUNT UNLOCK CONTAINER=ALL');
      dbms_output.put_line('reset password of ' || u);
    END IF;
    x('ALTER USER "' || u || '" PROFILE "$MON_PROFILE" CONTAINER=ALL');
  END;
BEGIN
  -- pair.sh names the primary; after a switchover it must be edited first
  SELECT COUNT(*) INTO n FROM v\$database WHERE database_role = 'PRIMARY' AND open_mode = 'READ WRITE';
  IF n = 0 THEN
    raise_application_error(-20001, '$PRIMARY_SID on $PRIMARY_HOST is not an open primary; check pair.sh');
  END IF;
  SELECT COUNT(*) INTO n FROM dba_profiles WHERE profile = '$MON_PROFILE';
  IF n = 0 THEN
    x('CREATE PROFILE "$MON_PROFILE" LIMIT PASSWORD_LIFE_TIME UNLIMITED CONTAINER=ALL');
    dbms_output.put_line('created profile $MON_PROFILE');
  END IF;
  x('ALTER PROFILE "$MON_PROFILE" LIMIT PASSWORD_LIFE_TIME UNLIMITED PASSWORD_GRACE_TIME UNLIMITED'
    || ' PASSWORD_REUSE_TIME UNLIMITED PASSWORD_REUSE_MAX UNLIMITED CONTAINER=ALL');
  ensure_user('$MON_USER', '$MON_PW');
  ensure_user('$DG_USER', '$DG_PW');
  x('GRANT CREATE SESSION TO "$MON_USER" CONTAINER=ALL');
$grants  x('ALTER USER "$MON_USER" SET CONTAINER_DATA=ALL CONTAINER=CURRENT');
  SELECT COUNT(*) INTO n FROM v\$pwfile_users WHERE username = '$DG_USER' AND sysdg = 'TRUE';
  IF n = 0 THEN
    x('GRANT SYSDG TO "$DG_USER" CONTAINER=ALL');
    dbms_output.put_line('granted SYSDG to $DG_USER');
  END IF;
END;
/
exit
SQL

# --- password file -----------------------------------------------------------
p_home="$(oh "$PRIMARY_HOST" "$PRIMARY_SID")"
s_home="$(oh "$STANDBY_HOST" "$STANDBY_SID")"
[ -n "$p_home" ] && [ -n "$s_home" ] || { echo "provision: SID missing from /etc/oratab" >&2; exit 1; }
p_file="$p_home/dbs/orapw$PRIMARY_SID"
s_file="$s_home/dbs/orapw$STANDBY_SID"
sum_of() { ssh -n "${SSH_OPTS[@]}" "$1" "sudo sha256sum '$2'" | cut -d' ' -f1; }
# the standby must already have a password file (redo transport needs one);
# this script replaces it, it never creates the first one
ssh -n "${SSH_OPTS[@]}" "$STANDBY_HOST" "sudo test -f '$s_file'" ||
  { echo "provision: $s_file missing on $STANDBY_HOST (or the host is unreachable)" >&2; exit 1; }
p_sum="$(sum_of "$PRIMARY_HOST" "$p_file")"
s_sum="$(sum_of "$STANDBY_HOST" "$s_file")"
if [ "$p_sum" = "$s_sum" ]; then
  log "$STANDBY_HOST" "password file equals the primary's, keeping it"
else
  # keep owner, group and mode of the standby's file; write next to it, then rename
  meta="$(ssh -n "${SSH_OPTS[@]}" "$STANDBY_HOST" "sudo stat -c '%U:%G %a' '$s_file'")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  ssh -n "${SSH_OPTS[@]}" "$STANDBY_HOST" "sudo cp -p '$s_file' '$s_file.bak-$stamp'"
  # a failed or short copy removes its .new file and leaves the old file in place
  ssh "${SSH_OPTS[@]}" "$PRIMARY_HOST" "sudo cat '$p_file'" </dev/null |
    ssh "${SSH_OPTS[@]}" "$STANDBY_HOST" "sudo rm -f '$s_file.new' &&
      sudo sh -c 'umask 077; cat > \"$s_file.new\"' &&
      sudo chown '${meta% *}' '$s_file.new' && sudo chmod '${meta#* }' '$s_file.new' &&
      [ \"\$(sudo sha256sum '$s_file.new' | cut -d' ' -f1)\" = '$p_sum' ] &&
      sudo mv '$s_file.new' '$s_file' || { sudo rm -f '$s_file.new'; exit 1; }" ||
    { echo "[$STANDBY_HOST] password file copy failed; $s_file is unchanged" >&2; exit 1; }
  log "$STANDBY_HOST" "copied the primary's password file (backup $s_file.bak-$stamp)"
fi

# --- login check from the observer VM ----------------------------------------
# check <descriptor> <user> <password> <mode> <sql>: sqlplus on the observer
fail=0 out=""
check() {
  local target=$1 user=$2 pw=$3 mode=$4 sql=$5
  out="$(printf 'whenever sqlerror exit failure\nconnect "%s"/"%s"@%s %s\nset head off feedback off pages 0\n%s\nexit\n' \
    "$user" "$pw" "$target" "$mode" "$sql" |
    ssh "${SSH_OPTS[@]}" "$OBSERVER_HOST" \
      "sudo -u oracle env ORACLE_HOME=$OBSERVER_ORACLE_HOME $OBSERVER_ORACLE_HOME/bin/sqlplus -s -L /nolog" 2>&1)" || {
    echo "[$OBSERVER_HOST] login $user@$target $mode failed: $(echo "$out" | grep -m1 ORA- || echo "$out" | head -1)" >&2
    fail=1; return 0; }
  log "$OBSERVER_HOST" "$user@$target ${mode:+$mode }-> $(echo "$out" | xargs)"
}
p_tns="$PRIMARY_HOST.$DOMAIN:$LISTENER_PORT/$PRIMARY_SID"
s_tns="$STANDBY_HOST.$DOMAIN:$LISTENER_PORT/$STANDBY_SID"
role_sql="select database_role || ' ' || open_mode from v\$database;"
check "$p_tns" "$DG_USER" "$DG_PW" "as sysdg" "$role_sql"
check "$s_tns" "$DG_USER" "$DG_PW" "as sysdg" "$role_sql"
# CONTAINER_DATA: from the root the common user must see every container in
# V$CON_SYSSTAT (without it, only the root's rows)
check "$p_tns" "$MON_USER" "$MON_PW" "" \
  "select 'containers v\$con_sysstat=' || (select count(distinct con_id) from v\$con_sysstat) || ' v\$containers=' || (select count(*) from v\$containers) from dual;"
case "$out" in
  *"v\$con_sysstat="*) seen=${out#*v\$con_sysstat=}; seen=${seen%% *}; all=${out##*v\$containers=}; all=${all%%[!0-9]*}
    if [ "$seen" != "$all" ]; then
      echo "[$OBSERVER_HOST] $MON_USER sees $seen of $all containers in v\$con_sysstat (CONTAINER_DATA)" >&2; fail=1
    fi ;;
  *) echo "[$OBSERVER_HOST] unexpected CONTAINER_DATA check output" >&2; fail=1 ;;
esac
if [ "$fail" = 1 ]; then
  echo "provision: a login failed; if the users existed before with other passwords, rerun with --reset-passwords" >&2
  exit 1
fi
