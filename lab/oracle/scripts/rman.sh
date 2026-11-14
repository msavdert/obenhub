#!/usr/bin/env bash
# Converge RMAN backups of the CDB19 Data Guard pair (ADR 0008 decision 9) from
# this box over ssh. Per database VM (lab/oracle/pair.sh: PRIMARY_HOST with
# PRIMARY_SID, STANDBY_HOST with STANDBY_SID):
#   - files/rman-backup.sh as /home/oracle/scripts/rman-backup.sh (oracle,
#     0750, as the CDB26 copy was); it backs up only while the database role
#     is PRIMARY, so the same script is on both hosts and the backups follow
#     the primary;
#   - the crontab lines of the oracle user for that instance, same schedule as
#     the hand-made CDB26 lines (level 0 Sunday, cumulative level 1 Monday to
#     Saturday, archived logs every 4 h) shifted to :45 so they never start
#     with CDB26's :30 and :15 jobs. Every managed line ends in the tag
#     "# obenhub: <SID>"; lines carrying that tag for this SID (and the
#     untagged lines of the first version of this script) are replaced by the
#     wanted ones, every other line is kept byte for byte. A crontab that
#     cannot be read aborts the run (only "no crontab for" counts as empty);
#   - "rman-backup.sh <SID> configure" on the VM, which converges, by the
#     current role of the database, the RMAN configuration, block change
#     tracking and control_file_record_keep_time 21 (see the script header).
#     The same code runs before every backup on a primary of a Data Guard
#     configuration, so a promoted standby gets the settings by itself.
#     Current settings are read first and every change is printed as
#     "old -> new".
# Nothing is stopped or restarted and no backup is started here. Idempotent: a
# second run prints "unchanged" everywhere.
# Revert: crontab -e as oracle and delete the lines tagged "# obenhub:"; per
# database RMAN "CONFIGURE ... CLEAR;" for the settings, "ALTER DATABASE
# DISABLE BLOCK CHANGE TRACKING;" for the tracking file, and ALTER SYSTEM SET
# control_file_record_keep_time = 7 (README.md, Backups).
# Usage: rman.sh [host ...]   (default: both database VMs)
# Assumes the ssh aliases of pair.sh, passwordless sudo on the VMs, operating
# system authentication for the oracle user, ORACLE_HOME read from /etc/oratab.
# Test hooks: SSH_BIN replaces ssh, SCRIPT_DEST moves the script (stub tests).
# shellcheck disable=SC2029  # remote command lines are built here on purpose
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/pair.sh"

SSH_BIN=${SSH_BIN:-ssh}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
SCRIPT_SRC="$dir/files/rman-backup.sh"
SCRIPT_DEST=${SCRIPT_DEST:-/home/oracle/scripts/rman-backup.sh}
[ -s "$SCRIPT_SRC" ] || { echo "rman: $SCRIPT_SRC is missing" >&2; exit 1; }

if [ "$#" -gt 0 ]; then hosts=("$@"); else hosts=("$PRIMARY_HOST" "$STANDBY_HOST"); fi
for h in "${hosts[@]}"; do
  case "$h" in
    "$PRIMARY_HOST"|"$STANDBY_HOST") ;;
    *) echo "rman: unknown host $h (pair.sh names $PRIMARY_HOST, $STANDBY_HOST)" >&2; exit 2 ;;
  esac
done

host=""
sid=""
log() { echo "[$host/$sid] $*"; }
# ora <command>: run a command as oracle on the current VM; stdin goes through
ora() {
  timeout --foreground 600 "$SSH_BIN" "${SSH_OPTS[@]}" "$host" "sudo -u oracle bash -c $(printf '%q' "$1")"
}

converge() {
  host="$1"
  if [ "$host" = "$PRIMARY_HOST" ]; then sid=$PRIMARY_SID; else sid=$STANDBY_SID; fi

  # --- script ----------------------------------------------------------------
  local want have
  want=$(sha256sum <"$SCRIPT_SRC" | cut -d' ' -f1)
  have=$(ora "sha256sum $SCRIPT_DEST 2>/dev/null | cut -d' ' -f1" </dev/null || true)
  if [ "$want" = "$have" ] && [ "$(ora "stat -c %a $SCRIPT_DEST" </dev/null)" = 750 ]; then
    log "$SCRIPT_DEST unchanged"
  else
    ora "mkdir -p /home/oracle/scripts && cat >$SCRIPT_DEST.new && chmod 750 $SCRIPT_DEST.new && mv $SCRIPT_DEST.new $SCRIPT_DEST" <"$SCRIPT_SRC"
    if [ -n "$have" ]; then log "$SCRIPT_DEST updated"; else log "$SCRIPT_DEST installed"; fi
  fi

  # --- crontab ---------------------------------------------------------------
  local tmp rc tag="# obenhub: $sid" s="[ ]"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp:?}'" RETURN
  # the exit status travels in the last line; stderr is merged to recognise
  # "no crontab for oracle"
  ora 'crontab -l 2>&1; echo "obenhub-rc=$?"' </dev/null >"$tmp/raw"
  rc=$(tail -n 1 "$tmp/raw")
  case "$rc" in obenhub-rc=*) rc=${rc#obenhub-rc=} ;; *) echo "[$host/$sid] cannot read the crontab (no status)" >&2; return 1 ;; esac
  sed '$d' "$tmp/raw" >"$tmp/cur"
  if [ "$rc" != 0 ]; then
    if grep -q '^no crontab for ' "$tmp/cur" && [ "$(wc -l <"$tmp/cur")" = 1 ]; then
      : >"$tmp/cur"
    else
      echo "[$host/$sid] cannot read the crontab (crontab -l exit $rc), nothing changed:" >&2
      cat "$tmp/cur" >&2
      return 1
    fi
  fi
  local sched=("45 1 * * 0 level0" "45 1 * * 1-6 level1" "45 */4 * * * arch") l
  : >"$tmp/want"
  for l in "${sched[@]}"; do
    # "<m h dom mon dow> <kind>" -> the line
    printf '%s %s %s %s%s\n' "${l% *}" "$SCRIPT_DEST" "$sid" "${l##* }" " $tag" >>"$tmp/want"
  done
  # managed: tagged lines of this SID, the untagged job lines and the comment
  # line of the first version (job lines that run this script for this SID only)
  local managed="(^[^#].*${s}${tag}\$|^[0-9*/,-]+${s}[0-9*/,-]+${s}[0-9*/,-]+${s}[0-9*/,-]+${s}[0-9*/,-]+${s}${SCRIPT_DEST}${s}${sid}${s}(level0|level1|arch)\$|^# obenhub: ${sid} RMAN, )"
  grep -Ev -- "$managed" "$tmp/cur" >"$tmp/keep" || true
  grep -E -- "$managed" "$tmp/cur" >"$tmp/have" || true
  if cmp -s "$tmp/have" "$tmp/want"; then
    log "crontab unchanged"
  else
    cat "$tmp/keep" "$tmp/want" >"$tmp/new"
    ora 'crontab -' <"$tmp/new"
    # read back: the unmanaged lines must be exactly the ones that were there
    ora 'crontab -l' </dev/null >"$tmp/after"
    { grep -Ev -- "$managed" "$tmp/after" || true; } | cmp -s - "$tmp/keep" || { echo "[$host/$sid] crontab read-back differs from what was written" >&2; return 1; }
    log "crontab: managed lines replaced"
    sed 's/^/    + /' "$tmp/want"
  fi

  # --- RMAN settings, block change tracking, record keep time ----------------
  ora "$SCRIPT_DEST $sid configure" </dev/null
}

for h in "${hosts[@]}"; do converge "$h"; done
