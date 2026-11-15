#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2016,SC2015
# Bring the CDB19 Data Guard pair back to its lab roles, CDB19 primary (open
# read write) on ora-au-lab and CDB19_STBY physical standby on ora-dg-stby,
# from any state that a fast-start failover or a failed run of the scenario
# fsfo-failover can leave behind. Idempotent: on a pair that is already in
# its roles it changes nothing. Usage:
#   lab/oracle/scripts/restore-roles.sh            converge, then wait for a healthy pair
#   lab/oracle/scripts/restore-roles.sh status     print the state, change nothing
# The scenario fsfo-failover sources this file and calls restore_roles (it
# only defines functions then).
#
# Steps, each chosen from the state read at the start of every round (the
# round repeats until the roles are right or RESTORE_TIMEOUT runs out):
#   1. CDB19 instance not running: startup mount (a nomount instance: alter
#      database mount). The standby's instance is started the same way.
#   2. Both databases report PRIMARY and CDB19 is only mounted (the failed-over
#      old primary): the observer reinstates it as a physical standby once it
#      is mounted (auto-reinstate TRUE). Wait REINSTATE_WAIT seconds for that,
#      then run "reinstate database cdb19" from the new primary.
#   3. CDB19 is a physical standby and CDB19_STBY the primary (roles swapped):
#      "switchover to cdb19" from CDB19_STBY, retried each round until the
#      broker accepts it (it refuses while apply is behind or the standby has
#      not caught up).
#   4. CDB19 is PRIMARY and mounted while CDB19_STBY is a physical standby
#      (the failover never happened): alter database open.
#   5. CDB19 PRIMARY open, CDB19_STBY physical standby: done; fast-start
#      failover is enabled again if the broker shows it disabled.
# Two databases that are both open read write as PRIMARY (split brain) are
# never touched: the script stops with status 2.
#
# Needs: ssh to ora-au-lab and ora-dg-stby with sudo, the lab adapter
# lab/oracle/scenarios/lib.sh. Run from the repository root or anywhere.
set -uo pipefail
declare -F rn >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/../scenarios/lib.sh"

RESTORE_TIMEOUT=${RESTORE_TIMEOUT:-1500}
REINSTATE_WAIT=${REINSTATE_WAIT:-180}
# epochs of the steps of the last restore_roles run, "" when the step did not happen
RR_MOUNT_AT="" RR_REINSTATE_SEEN_AT="" RR_REINSTATE_CMD_AT="" RR_STANDBY_AT="" RR_SWITCH_CMD_AT="" RR_RESTORED_AT=""
# "yes" when the observer did not reinstate within REINSTATE_WAIT and the command was needed
RR_REINSTATE_MANUAL=no
RR_LAST_ERR=""

rr_log() { log "restore-roles: $*"; }

# inst_state SID: DOWN, or STATUS|ROLE|OPEN_MODE of the instance (STARTED has
# no readable role: STARTED||); empty when the host cannot be read
inst_state() {
  local sid=$1 host n st
  host=$(sid_host "$sid") || return 1
  # the process command line is the full name, ora_pmon_<SID>
  # the exit status of pgrep is read on the VM ("rc=N" after the count), so that a failing
  # ssh, timeout or sudo (which also exits 1) is not mistaken for "no process": rc=1 is
  # DOWN, a missing or other rc line is unreadable and the caller retries
  local out rcl
  out=$(rn "$host" sh -c 'pgrep -c -f "$1"; echo "rc=$?"' _ "^ora_pmon_$sid\$" 2>/dev/null) || return 1
  rcl=$(grep '^rc=' <<<"$out" | tail -n 1)
  case $rcl in
    rc=0) n=$(grep -v '^rc=' <<<"$out" | head -n 1) ;;
    rc=1) echo DOWN; return 0 ;;
    *) return 1 ;;
  esac
  [ "${n:-0}" -ge 1 ] 2>/dev/null || return 1
  st=$(ora_sql "$sid" <<<'SELECT status FROM v$instance;' 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$st" ] || return 1
  if [ "$st" = STARTED ]; then echo 'STARTED||'; return 0; fi
  ora_sql "$sid" <<<"SELECT '$st|' || database_role || '|' || open_mode FROM v\$database;" 2>/dev/null | tr -d '\r' | head -n1
}

# dg_up COMMAND: the command through dgmgrl on whichever of the two databases
# answers (the standby host first: after a failover it is the primary); prints
# the output of the first host that connected
dg_up() {
  local sid out
  for sid in "$STANDBY_SID" "$PRIMARY_SID"; do
    out=$(dg "$sid" "$1" 2>&1) || continue
    grep -q '^Connected to' <<<"$out" || continue
    printf '%s\n' "$out"
    return 0
  done
  return 1
}

# dg_sysdg SID COMMAND: the command through dgmgrl logged on as C##OBENHUB_DG AS
# SYSDG to that database. A switchover, reinstate or enable needs it: with
# operating-system authentication the broker cannot restart the old primary
# afterwards (ORA-01017 on the static connect identifier, found in the record
# lab/oracle/results/role-staleness-2026-11-13/README.md and again by the
# first fsfo-failover trial). The password comes from lab/oracle/.env and goes
# to dgmgrl on stdin only.
dg_sysdg() {
  local sid=$1 host pw
  host=$(sid_host "$sid") || return 1
  pw=$( ( set -a; . "$LAB_DIR/.env"; printf '%s' "${ORA_DG_PASSWORD:0:30}" ) ) && [ "${#pw}" -eq 30 ] || return 1
  printf 'connect "%s"/"%s"@%s.%s:%s/%s as sysdg\n%s\n' "$DG_USER" "$pw" "$host" "$DOMAIN" "$LISTENER_PORT" "$sid" "$2" \
    | ora_sh "$sid" 'dgmgrl -silent' 2>&1
}

# fsfo_enabled: the broker reports fast-start failover enabled
# (grep without -q: under pipefail an early grep exit would make the pipe fail with 141)
fsfo_enabled() { dg_up 'show fast_start failover' | grep '^Fast-Start Failover: Enabled' >/dev/null; }

rr_state_line() { printf 'CDB19=%s CDB19_STBY=%s' "$1" "$2"; }

# restore_roles: converge; returns 0 when CDB19 is primary and open and
# CDB19_STBY is a physical standby, 1 when RESTORE_TIMEOUT ran out (RR_LAST_ERR
# says where), 2 for two open primaries
restore_roles() {
  local deadline a b mounted_seen="" out unreadable=0 bounce=0 sid cmd
  deadline=$(($(date +%s) + RESTORE_TIMEOUT))
  RR_MOUNT_AT="" RR_REINSTATE_SEEN_AT="" RR_REINSTATE_CMD_AT="" RR_STANDBY_AT="" RR_SWITCH_CMD_AT="" RR_RESTORED_AT="" RR_REINSTATE_MANUAL=no RR_LAST_ERR=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    a=$(inst_state "$PRIMARY_SID") && b=$(inst_state "$STANDBY_SID") || {
      unreadable=$((unreadable + 1)); RR_LAST_ERR="cannot read the instance states (round $unreadable)"; rr_log "$RR_LAST_ERR"; sleep 15; continue
    }
    rr_log "$(rr_state_line "$a" "$b")"
    case "$a|$b" in
      DOWN\|* | 'STARTED||'\|* | *\|DOWN | *\|'STARTED||')
        # a restart that the broker itself is doing (reinstate, switchover) must not be raced:
        # once we have seen it do either, act only on a state that persists
        if [ -n "$mounted_seen" ] || [ -n "$RR_SWITCH_CMD_AT" ] || [ -n "$RR_REINSTATE_CMD_AT" ]; then
          bounce=$((bounce + 1))
          if [ "$bounce" -lt 4 ]; then rr_log "instance restarting (broker at work?), waiting ($bounce)"; sleep 15; continue; fi
        fi
        bounce=0
        case "$a" in
          DOWN) rr_log "startup mount on $PRIMARY_SID"; sid=$PRIMARY_SID; cmd='startup mount' ;;
          'STARTED||') rr_log "alter database mount on $PRIMARY_SID"; sid=$PRIMARY_SID; cmd='alter database mount;' ;;
          *) case "$b" in
               DOWN) rr_log "startup mount on $STANDBY_SID"; sid=$STANDBY_SID; cmd='startup mount' ;;
               *) rr_log "alter database mount on $STANDBY_SID"; sid=$STANDBY_SID; cmd='alter database mount;' ;;
             esac ;;
        esac
        ora_sql "$sid" <<<"$cmd" >/dev/null 2>&1 || { RR_LAST_ERR="$cmd on $sid failed"; rr_log "$RR_LAST_ERR"; sleep 15; continue; }
        [ "$sid" != "$PRIMARY_SID" ] || [ -n "$RR_MOUNT_AT" ] || RR_MOUNT_AT=$(date +%s)
        continue ;;
    esac
    bounce=0
    # a = STATUS|ROLE|MODE of CDB19, b = of CDB19_STBY
    local ar=${a#*|} br=${b#*|}
    ar=${ar%%|*}; br=${br%%|*}
    local am=${a##*|} bm=${b##*|}
    if [ "$ar" = PRIMARY ] && [ "$br" = PRIMARY ]; then
      if [ "$am" = 'READ WRITE' ] && [ "$bm" = 'READ WRITE' ]; then
        RR_LAST_ERR="both databases are open read write as PRIMARY: not touched"; rr_log "$RR_LAST_ERR"; return 2
      fi
      if [ "$am" = MOUNTED ] && [ "$bm" = 'READ WRITE' ]; then
        # the old primary, mounted: the observer reinstates it
        [ -n "$mounted_seen" ] || { mounted_seen=$(date +%s); RR_REINSTATE_SEEN_AT=$mounted_seen; }
        if [ $(($(date +%s) - mounted_seen)) -ge "$REINSTATE_WAIT" ]; then
          rr_log "no auto-reinstate within ${REINSTATE_WAIT}s: reinstate database cdb19"
          RR_REINSTATE_MANUAL=yes
          RR_REINSTATE_CMD_AT=$(date +%s)
          out=$(dg_sysdg "$STANDBY_SID" 'reinstate database cdb19') || out="dgmgrl did not connect"
          rr_log "reinstate: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"
          mounted_seen=$(date +%s)
        fi
        sleep 10; continue
      fi
      RR_LAST_ERR="unexpected state with two primaries: $(rr_state_line "$a" "$b")"; rr_log "$RR_LAST_ERR"; sleep 15; continue
    fi
    if [ "$ar" = 'PHYSICAL STANDBY' ] && [ "$br" = PRIMARY ]; then
      mounted_seen=""
      [ -n "$RR_STANDBY_AT" ] || RR_STANDBY_AT=$(date +%s)
      # switchover to cdb19 from the primary, logged on as SYSDG (operating-system
      # authentication is refused, see dg_sysdg); the broker refuses until cdb19
      # is ready (apply running, caught up, synchronized), so validate first and
      # retry in the next round
      if dg_sysdg "$STANDBY_SID" 'validate database cdb19' | grep '^ *Ready for Switchover: *Yes' >/dev/null; then
        [ -n "$RR_SWITCH_CMD_AT" ] || RR_SWITCH_CMD_AT=$(date +%s)
        rr_log "switchover to cdb19"
        out=$(dg_sysdg "$STANDBY_SID" 'switchover to cdb19') || out="dgmgrl did not connect"
        rr_log "switchover: $(tr '\n' ' ' <<<"$out" | tail -c 300)"
      else
        rr_log "cdb19 is not ready for switchover yet"
      fi
      sleep 20; continue
    fi
    if [ "$ar" = PRIMARY ] && [ "$am" = MOUNTED ] && [ "$br" = 'PHYSICAL STANDBY' ]; then
      rr_log "CDB19 is PRIMARY and mounted, the standby is a standby: alter database open"
      ora_sql "$PRIMARY_SID" <<<'alter database open;' >/dev/null 2>&1 || { RR_LAST_ERR="alter database open on $PRIMARY_SID failed"; rr_log "$RR_LAST_ERR"; }
      sleep 5; continue
    fi
    if [ "$ar" = PRIMARY ] && [ "$am" = 'READ WRITE' ] && [ "$br" = 'PHYSICAL STANDBY' ]; then
      # dgmgrl exits 0 on ORA-16651 and the like: enable, then verify, bounded (the
      # standby may still be synchronizing), and fail loudly when it stays disabled
      if ! fsfo_enabled; then
        local t0 fs_ok=""
        t0=$(date +%s)
        while [ $(($(date +%s) - t0)) -lt "${FSFO_ENABLE_WAIT:-300}" ]; do
          rr_log "fast-start failover is not enabled: enable fast_start failover"
          out=$(dg_sysdg "$PRIMARY_SID" 'enable fast_start failover') || out="dgmgrl did not connect"
          rr_log "enable: $(tr '\n' ' ' <<<"$out" | tail -c 200)"
          sleep 20
          if fsfo_enabled; then fs_ok=1; break; fi
        done
        [ -n "$fs_ok" ] || { RR_LAST_ERR="fast-start failover still disabled ${FSFO_ENABLE_WAIT:-300}s after enable fast_start failover"; rr_log "$RR_LAST_ERR"; return 1; }
      fi
      RR_RESTORED_AT=$(date +%s)
      rr_log "roles restored: $(rr_state_line "$a" "$b")"
      return 0
    fi
    RR_LAST_ERR="no rule for the state $(rr_state_line "$a" "$b")"; rr_log "$RR_LAST_ERR"; sleep 15
  done
  [ -n "$RR_LAST_ERR" ] || RR_LAST_ERR="roles not restored within ${RESTORE_TIMEOUT}s"
  rr_log "giving up: $RR_LAST_ERR"
  return 1
}

# the pair is usable again: the roles are right and the shared health predicate holds
restore_and_wait() {
  restore_roles || return $?
  wait_until 600 "pair healthy (roles restored)" healthy_pair
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    status)
      echo "CDB19 $(inst_state "$PRIMARY_SID")"
      echo "CDB19_STBY $(inst_state "$STANDBY_SID")"
      dg_up 'show configuration' ;;
    '')
      # one lab run at a time (lab/scenarios/guard.sh): never in the middle of a scenario or
      # suite. Sourced from the scenario's own revert this block does not run: the scenario
      # holds the lock itself.
      lock_acquire restore-roles || { echo "restore-roles: another lab run holds $SUITE_LOCK_FILE; the pair is not touched" >&2; exit 3; }
      restore_and_wait ;;
    *) echo "usage: restore-roles.sh [status]" >&2; exit 2 ;;
  esac
fi
