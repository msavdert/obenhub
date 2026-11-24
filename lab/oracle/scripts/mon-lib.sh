# shellcheck shell=bash
# Shared by provision.sh and cdb26-check.sh; sourced, never run. The caller has
# set $dir (lab/oracle), sourced lab/pgha/lab-config.sh and pair.sh, and set
# -euo pipefail. It provides:
#   mon_env           lab/oracle/.env (gen-env.sh adds missing keys, keeps values),
#                     MON_PW and DG_PW: the 30 characters Oracle allows
#                     (ORA-00972) of the 32 hex characters gen-env.sh writes
#   log, oh, sysdba   progress line, Oracle home of a SID, SQL as SYSDBA over ssh
#   mon_sql           the SQL that converges the profile and the users
# shellcheck disable=SC2029,SC2154  # remote command lines are built here on purpose; $dir is the caller's

mon_env() {
  "$dir/../scripts/gen-env.sh" "$dir/.env" ORA_MON_PASSWORD ORA_DG_PASSWORD
  set -a
  # shellcheck source=/dev/null
  . "$dir/.env"
  set +a
  MON_PW=${ORA_MON_PASSWORD:0:30}
  DG_PW=${ORA_DG_PASSWORD:0:30}
  local pw
  for pw in "$MON_PW" "$DG_PW"; do
    # hex only: the value is embedded in SQL and in a data source URL unquoted
    case "$pw" in *[!0-9a-f]*|"") echo "${0##*/}: passwords in .env must be hex (gen-env.sh)" >&2; return 1 ;; esac
    [ "${#pw}" -eq 30 ] || { echo "${0##*/}: passwords in .env must have at least 30 characters" >&2; return 1; }
  done
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
log() { echo "[$1] $2"; }

# oh <host> <sid>: the Oracle home of a SID from /etc/oratab
oh() { ssh -n "${SSH_OPTS[@]}" "$1" "awk -F: -v s='$2' '\$1==s {print \$2}' /etc/oratab"; }

# sysdba <host> <sid> < sql: run SQL as SYSDBA through the local bequeath
sysdba() {
  local home; home="$(oh "$1" "$2")"
  [ -n "$home" ] || { echo "${0##*/}: $2 not in /etc/oratab on $1" >&2; return 1; }
  ssh "${SSH_OPTS[@]}" "$1" "sudo -u oracle env ORACLE_SID=$2 ORACLE_HOME=$home $home/bin/sqlplus -s -L / as sysdba"
}

# The views follow the oracledb receiver README at contrib v0.164.0: instance
# detection, metrics and per-PDB metrics (CONTAINER=ALL). ASM, the events
# (query samples, top queries) and the PDB-connection views are left out:
# the lab has no ASM, runs no events and connects to the root.
MON_VIEWS="V_\$INSTANCE V_\$DATABASE V_\$DATAFILE V_\$SESSION V_\$SYSSTAT V_\$RESOURCE_LIMIT
V_\$OSSTAT V_\$SGAINFO V_\$CON_SYSSTAT V_\$CON_SYSMETRIC V_\$CONTAINERS
DBA_TABLESPACES DBA_DATA_FILES DBA_TABLESPACE_USAGE_METRICS
CDB_TABLESPACE_USAGE_METRICS CDB_TABLESPACES CDB_DATA_FILES"

# mon_sql <sid> <host> <with_dg 0|1> <reset 0|1>: the PL/SQL block that
# converges profile $MON_PROFILE and user $MON_USER (CREATE SESSION, SELECT on
# MON_VIEWS, CONTAINER_DATA=ALL) on an open primary; with_dg=1 adds $DG_USER
# and its SYSDG grant (the CDB19 pair). Needs mon_env first.
mon_sql() {
  local sid=$1 host=$2 with_dg=$3 reset=$4 v grants="" dg_ensure="" dg_sysdg=""
  for v in $MON_VIEWS; do
    grants="$grants  x('GRANT SELECT ON SYS.$v TO \"$MON_USER\" CONTAINER=ALL');
"
  done
  if [ "$with_dg" = 1 ]; then
    dg_ensure="
  ensure_user('$DG_USER', '$DG_PW');"
    dg_sysdg="
  SELECT COUNT(*) INTO n FROM v\$pwfile_users WHERE username = '$DG_USER' AND sysdg = 'TRUE';
  IF n = 0 THEN
    x('GRANT SYSDG TO \"$DG_USER\" CONTAINER=ALL');
    dbms_output.put_line('granted SYSDG to $DG_USER');
  END IF;"
  fi
  cat <<SQL
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
    raise_application_error(-20001, '$sid on $host is not an open primary; check pair.sh');
  END IF;
  SELECT COUNT(*) INTO n FROM dba_profiles WHERE profile = '$MON_PROFILE';
  IF n = 0 THEN
    x('CREATE PROFILE "$MON_PROFILE" LIMIT PASSWORD_LIFE_TIME UNLIMITED CONTAINER=ALL');
    dbms_output.put_line('created profile $MON_PROFILE');
  END IF;
  x('ALTER PROFILE "$MON_PROFILE" LIMIT PASSWORD_LIFE_TIME UNLIMITED PASSWORD_GRACE_TIME UNLIMITED'
    || ' PASSWORD_REUSE_TIME UNLIMITED PASSWORD_REUSE_MAX UNLIMITED CONTAINER=ALL');
  ensure_user('$MON_USER', '$MON_PW');$dg_ensure
  x('GRANT CREATE SESSION TO "$MON_USER" CONTAINER=ALL');
$grants  x('ALTER USER "$MON_USER" SET CONTAINER_DATA=ALL CONTAINER=CURRENT');$dg_sysdg
END;
/
exit
SQL
}
