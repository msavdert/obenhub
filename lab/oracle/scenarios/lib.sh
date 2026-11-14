#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2029,SC2016,SC2034
# Oracle adapter for the shared fault scenario machinery in
# lab/scenarios/lib-core.sh: it binds the core to the CDB19 Data Guard pair
# and the observer VM over ssh (aliases and SIDs from lab/oracle/pair.sh) and
# to the backend Compose project obenhub-oracle on this box. Source it from a
# scenario; do not run it. The Patroni and etcd helpers of the core are not
# defined here; no Oracle scenario calls them.
#
# Databases are reached as the oracle OS user with operating-system
# authentication (sqlplus / as sysdba, dgmgrl /): no password is read, stored
# or passed. ORACLE_HOME comes from /etc/oratab on the host. The broker
# configuration is the one of the pair, CDB19 and CDB19_STBY (the VMs also hold
# CDB19B and CDB26, which no scenario touches).
#
# Needs: ssh to ora-au-lab, ora-dg-stby, ora-dg-obs (user with sudo), curl, jq,
# docker, the backend (mise run lab:oracle:mon:up) and the Collector
# (mise run lab:oracle:collector) running.

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
LAB_DIR="$(cd "$SC_DIR/.." && pwd)"
# shellcheck source=lab/oracle/pair.sh
. "$LAB_DIR/pair.sh"
RESULTS="$LAB_DIR/results/runs.jsonl"
CLUSTER=cdb19
VL=${VL:-http://127.0.0.1:59428}
AM=${AM:-http://127.0.0.1:59093}
VMALERT=${VMALERT:-http://127.0.0.1:58880}
VMALERT_C=obenhub-oracle-vmalert
AM_C=obenhub-oracle-alertmanager
VM=${VM:-http://127.0.0.1:58428}
NODES=("$PRIMARY_SID" "$STANDBY_SID")
ETCD_MEMBERS=()
# the order of the mounts in lab/oracle/mon/compose.yaml
CONFIG_FILES=("$LAB_DIR/mon/vmalert/inventory.yml" "$LAB_DIR/../packs/collector/rules.yml" "$LAB_DIR/../packs/oracledb-dg/rules.yml" "$LAB_DIR/../mon/alertmanager.yml")
# pack files sort by name inside the container: collector.yml, oracledb-dg.yml
VMALERT_LOADED_CAT="cat /etc/vmalert/inventory.yml /etc/vmalert/pack/collector.yml /etc/vmalert/pack/oracledb-dg.yml"

# shellcheck source=lab/scenarios/lib-core.sh
. "$SC_DIR/../../scenarios/lib-core.sh"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
# rn HOST COMMAND...: run a command as root on the host; every argument is
# quoted. -n: ssh must not read the caller's stdin.
# REMOTE_TIMEOUT bounds every remote command: SSH_OPTS only bound the connect
# and a dead link, not a hung dgmgrl, sqlplus or systemctl.
REMOTE_TIMEOUT=${REMOTE_TIMEOUT:-180}
# --foreground keeps ssh in the caller's process group: Ctrl-C reaches it, and
# it is not stopped by SIGTTIN when run from a terminal.
rn() { local h=$1; shift; timeout --foreground "$REMOTE_TIMEOUT" ssh -n "${SSH_OPTS[@]}" "$h" "sudo $(printf '%q ' "$@")"; }

# sid_host SID: the VM that runs the instance
sid_host() { case "$1" in "$PRIMARY_SID") echo "$PRIMARY_HOST" ;; "$STANDBY_SID") echo "$STANDBY_HOST" ;; *) return 1 ;; esac; }

# ora_sh SID SCRIPT: run a bash script as oracle with ORACLE_SID and the
# ORACLE_HOME that /etc/oratab lists for it; SCRIPT is the first argument of
# bash -c, stdin passes through (used by ora_sql). The SID is validated, it is
# interpolated into the remote command line.
ora_sh() {
  local sid=$1 host
  [[ $sid =~ ^[A-Z0-9_]+$ ]] || return 1
  host=$(sid_host "$sid") || return 1
  shift
  timeout --foreground "$REMOTE_TIMEOUT" ssh "${SSH_OPTS[@]}" "$host" "sudo -u oracle env ORACLE_SID=$sid bash -c $(printf '%q' "export ORACLE_HOME=\$(awk -F: -v s=\$ORACLE_SID '\$1==s{print \$2}' /etc/oratab); export PATH=\$ORACLE_HOME/bin:\$PATH; $1")"
}
# ora_sql SID: SQL from stdin, run as sysdba with OS authentication; plain
# output, no banner, no headings, errors stop the script (status 1)
ora_sql() {
  ora_sh "$1" 'sqlplus -S -L / as sysdba <<EOF
set pagesize 0 feedback off heading off verify off trimspool on linesize 400
whenever sqlerror exit 1
$(cat)
EOF'
}
# dg SID COMMAND: one dgmgrl command through OS authentication on that
# database's host
dg() { ora_sh "$1" "dgmgrl -silent / $(printf '%q' "$2")" </dev/null; }
# retry COMMAND...: up to three attempts 15 s apart; for the revert steps,
# where one dropped ssh connection must not leave the fault in place
retry() {
  local i
  for i in 1 2 3; do
    "$@" && return 0
    [ "$i" = 3 ] || { log "attempt $i failed, retrying in 15 s: $*"; sleep 15; }
  done
  return 1
}

# the observer: systemd template unit dg-observer@<configuration> on
# ora-dg-obs (runs /home/oracle/scripts/observer.sh start|stop <configuration>)
OBSERVER_UNIT=dg-observer@cdb19.service
observer_active() { [ "$(rn "$OBSERVER_HOST" systemctl is-active "$OBSERVER_UNIT")" = active ] && rn "$OBSERVER_HOST" pgrep -u oracle -f /u01/app/oracle/dg/cdb19/fsfo.dat >/dev/null; }

# show configuration of the pair, from the primary
config_ok() {
  local c; c=$(dg "$PRIMARY_SID" 'show configuration') || return 1
  grep -q '^SUCCESS' <<<"$c" && grep -q 'Fast-Start Failover: Enabled' <<<"$c" && grep -qi '^ *cdb19 *- Primary' <<<"$c" && grep -qi '^ *cdb19_stby .*Physical standby' <<<"$c"
}
# the broker's view of the observer, from the primary: a host name, not (none)
observer_in_broker() {
  local o; o=$(dg "$PRIMARY_SID" 'show fast_start failover') || return 1
  grep -q '^ *Observer: *[^( ]' <<<"$o"
}
# transport and apply lag in seconds on the standby, "T A", empty when unknown
lag_pair() {
  ora_sql "$STANDBY_SID" <<'SQL' | tr -s ' \n' ' ' | sed 's/ $//'
SELECT NVL(MAX(CASE name WHEN 'transport lag' THEN EXTRACT(DAY FROM TO_DSINTERVAL(value))*86400 + EXTRACT(HOUR FROM TO_DSINTERVAL(value))*3600 + EXTRACT(MINUTE FROM TO_DSINTERVAL(value))*60 + EXTRACT(SECOND FROM TO_DSINTERVAL(value)) END), -1) || ' ' ||
       NVL(MAX(CASE name WHEN 'apply lag' THEN EXTRACT(DAY FROM TO_DSINTERVAL(value))*86400 + EXTRACT(HOUR FROM TO_DSINTERVAL(value))*3600 + EXTRACT(MINUTE FROM TO_DSINTERVAL(value))*60 + EXTRACT(SECOND FROM TO_DSINTERVAL(value)) END), -1)
FROM v$dataguard_stats WHERE name IN ('transport lag', 'apply lag') AND value IS NOT NULL;
SQL
}
# lag_small [LIMIT]: both lags known and at most LIMIT seconds (default 10)
lag_small() {
  local l; l=$(lag_pair) || return 1
  awk -v l="$l" -v m="${1:-10}" 'BEGIN{split(l, a, " "); exit !(a[1] != "" && a[2] != "" && a[1] >= 0 && a[2] >= 0 && a[1] <= m && a[2] <= m)}'
}
# apply_running: a managed recovery process exists on the standby
# apply_count: number of managed recovery processes on the standby; empty when
# the query failed (callers must not read empty as zero)
apply_count() { ora_sql "$STANDBY_SID" <<<"SELECT COUNT(*) FROM v\$dataguard_process WHERE role = 'managed recovery';"; }
apply_running() { [ "$(apply_count)" -ge 1 ] 2>/dev/null; }
# log_switch: one log switch on the primary (the smallest redo source that
# touches no schema object)
log_switch() { ora_sql "$PRIMARY_SID" <<<'ALTER SYSTEM ARCHIVE LOG CURRENT;' >/dev/null; }
# redo_generator PARENT: one log switch every 20 s while process PARENT lives.
# Run it in the background and kill it in revert; redo must keep flowing for a
# lag to grow.
# Each step runs as a child it waits for, so TERM (stop_generator) ends the
# running ssh or sleep too instead of leaving it behind (it would otherwise
# keep the host-wide lock of guard.sh open after the run).
redo_generator() {
  # the step's own children first (timeout, then ssh through timeout's TERM)
  trap 'pkill -TERM -P "$!" 2>/dev/null; kill "$!" 2>/dev/null; exit 0' TERM
  while kill -0 "$1" 2>/dev/null; do
    log_switch & wait "$!"
    sleep 20 & wait "$!"
  done
}
# start_generator / stop_generator: GEN_PID holds the running generator
GEN_PID=""
start_generator() { redo_generator "$$" & GEN_PID=$!; }
stop_generator() { [ -z "$GEN_PID" ] || { kill "$GEN_PID" 2>/dev/null; wait "$GEN_PID" 2>/dev/null; GEN_PID=""; }; }
# sync_ok: the primary's protection level equals its mode and fast-start
# failover is SYNCHRONIZED
sync_ok() {
  [ "$(ora_sql "$PRIMARY_SID" <<'SQL'
SELECT CASE WHEN protection_level = protection_mode AND fs_failover_status = 'SYNCHRONIZED' THEN 1 ELSE 0 END FROM v$database;
SQL
)" -eq 1 ] 2>/dev/null
}
# healthy_pair: everything lab_precondition checks about the databases, as a
# predicate for wait_until (used after a revert)
healthy_pair() { config_ok && observer_in_broker && observer_active && apply_running && lag_small; }

# component versions: the Oracle release of both databases and the Collector
component_versions() {
  {
    local s v
    for s in "$PRIMARY_SID" "$STANDBY_SID"; do
      v=$(ora_sql "$s" <<<'SELECT version_full FROM v$instance;' | head -n1)
      printf '%s %s\n' "$s" "${v:-unknown}"
    done
    rn "$OBSERVER_HOST" otelcol-contrib --version | sed 's/ version / /'
  } | jq -R . | jq -s -c .
}

lab_precondition() {
  local role
  config_ok || { PRE_ERR="broker configuration of the pair is not SUCCESS with fast-start failover enabled and cdb19 primary, cdb19_stby physical standby"; return 1; }
  observer_in_broker || { PRE_ERR="the broker shows no fast-start failover observer"; return 1; }
  observer_active || { PRE_ERR="observer unit $OBSERVER_UNIT or its process is not running on $OBSERVER_HOST"; return 1; }
  role=$(ora_sql "$PRIMARY_SID" <<<'SELECT database_role FROM v$database;') || { PRE_ERR="cannot query $PRIMARY_SID"; return 1; }
  [ "$role" = PRIMARY ] || { PRE_ERR="$PRIMARY_SID is $role, not PRIMARY"; return 1; }
  role=$(ora_sql "$STANDBY_SID" <<<'SELECT database_role FROM v$database;') || { PRE_ERR="cannot query $STANDBY_SID"; return 1; }
  [ "$role" = 'PHYSICAL STANDBY' ] || { PRE_ERR="$STANDBY_SID is $role, not PHYSICAL STANDBY"; return 1; }
  apply_running || { PRE_ERR="redo apply is not running on $STANDBY_SID"; return 1; }
  wait_until 60 "transport and apply lag at most 10s" lag_small || { PRE_ERR="lag on $STANDBY_SID is not small: $(lag_pair)"; return 1; }
  [ "$(rn "$OBSERVER_HOST" systemctl is-active otelcol-contrib)" = active ] || { PRE_ERR="otelcol-contrib is not active on $OBSERVER_HOST"; return 1; }
  [ "$(vm_query 'count(last_over_time(oracledb.collection.heartbeat[1m]))')" = 2 ] || { PRE_ERR="VictoriaMetrics does not hold both Oracle targets (heartbeat)"; return 1; }
}
