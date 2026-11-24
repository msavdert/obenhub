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
. "$dir/../pgha/lab-config.sh"
lab_config "$dir/pair.sh"

reset=0
case "${1:-}" in
  --reset-passwords) reset=1 ;;
  "") ;;
  *) echo "usage: provision.sh [--reset-passwords]" >&2; exit 2 ;;
esac

# shellcheck source=lab/oracle/scripts/mon-lib.sh
. "$dir/scripts/mon-lib.sh"
mon_env

# --- users, profile and grants on the primary --------------------------------
# The views the user may read are MON_VIEWS in mon-lib.sh.
log "$PRIMARY_HOST" "profile, users and grants on $PRIMARY_SID"
mon_sql "$PRIMARY_SID" "$PRIMARY_HOST" 1 "$reset" | sysdba "$PRIMARY_HOST" "$PRIMARY_SID"

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
