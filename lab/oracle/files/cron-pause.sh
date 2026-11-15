#!/bin/bash
# Pause and restore one managed RMAN cron line of the oracle user, with a
# safety net on this VM. Used by lab/oracle/scenarios/backup-stale.sh, which
# pipes it to /usr/local/sbin/obenhub-cron-pause on the database VM (root).
# usage: obenhub-cron-pause pause <SID> <kind> <deadline-epoch>
#        obenhub-cron-pause restore
#        obenhub-cron-pause net          (what the timer runs)
#        obenhub-cron-pause status
# The crontab is read strictly (as lab/oracle/scripts/rman.sh does): only
# "no crontab for <user>" counts as empty, any other failure of crontab -l
# aborts and nothing is written, so a transient read failure cannot replace
# the crontab with a few lines.
# pause    finds the one active crontab line of the oracle user that ends in
#          "rman-backup.sh <SID> <kind> # obenhub: <SID>" (the tag of
#          lab/oracle/scripts/rman.sh), saves the whole crontab and the line,
#          installs the safety net, and only then comments the line out with
#          the prefix "#obenhub-paused# ". Refuses when a pause is active or a
#          paused line is already in the crontab.
# restore  puts every paused line back, from the line itself (the saved state
#          is not needed): a paused line whose original is also present as an
#          active line (lab:oracle:rman ran meanwhile and appended a new one)
#          is dropped, otherwise it is un-prefixed in place; when the saved
#          line is in neither form it is appended. Other lines are untouched.
#          Then it compares the crontab with the saved copy and prints
#          "crontab identical to the saved copy" or "crontab differs from the
#          saved copy"; on a difference the saved state is KEPT, renamed to
#          <state>.kept-<epoch>, never deleted. It removes the safety net and
#          the state. Safe to run twice and with nothing paused ("nothing
#          paused"). Non-zero when the crontab cannot be read or the restore
#          cannot be verified; nothing is removed then.
# net      restore, but only once the deadline has passed; before it, nothing.
# Safety net: systemd timer obenhub-cron-restore.timer (root, enabled, so it
# survives a reboot of this VM). OnCalendar at the deadline with
# Persistent=true; OnBootSec=5min; and OnUnitInactiveSec=15min, so a restore
# that fails (the service exits non-zero) is repeated every 15 minutes until it
# succeeds, which removes the units; there is no cap on the retries. The timer
# also runs the service every 15 minutes before the deadline, and those runs do
# nothing. The service checks the deadline itself,
# so a boot after a missed deadline restores within 5 minutes of the boot
# (reasoning, not tested with a reboot), and a run before the deadline does
# nothing. A transient systemd-run timer would not survive a reboot, which is
# why this is a real unit. Cron is not used for the net: a cron line cannot
# name a year, and a minute missed while the VM is down is not run later.
# State: /var/lib/obenhub-cron-pause (crontab.orig, line, deadline).
set -euo pipefail
USER_NAME=oracle
# test hooks (stub tests): CP_STATE, CP_UNITDIR, CP_LOCK, CP_NOROOT=1
STATE=${CP_STATE:-/var/lib/obenhub-cron-pause}
UNITDIR=${CP_UNITDIR:-/etc/systemd/system}
UNIT=obenhub-cron-restore
SELF=/usr/local/sbin/obenhub-cron-pause
PREFIX='#obenhub-paused# '

[ "$(id -u)" = 0 ] || [ -n "${CP_NOROOT:-}" ] || { echo "run as root" >&2; exit 2; }
mkdir -p "$(dirname "$STATE")"
exec 8>"${CP_LOCK:-/run/obenhub-cron-pause.lock}"
flock 8

# cron_get FILE: the crontab of the user into FILE, byte for byte; an empty
# file only for "no crontab for"; status 1 (message on stderr) otherwise
cron_get() {
  local f=$1 rc=0
  runuser -u "$USER_NAME" -- crontab -l >"$f" 2>"$f.err" || rc=$?
  if [ "$rc" != 0 ]; then
    if grep -q '^no crontab for ' "$f.err" && [ "$(wc -l <"$f.err")" = 1 ]; then
      : >"$f"
    else
      echo "cannot read the crontab (crontab -l exit $rc), nothing changed:" >&2
      cat "$f.err" >&2
      rm -f "$f.err"
      return 1
    fi
  fi
  rm -f "$f.err"
}
cron_put() { runuser -u "$USER_NAME" -- crontab -; }

net_install() {
  local deadline=$1
  cat >"$UNITDIR/$UNIT.service" <<EOF
[Unit]
Description=obenhub: restore the paused RMAN cron line (safety net)

[Service]
Type=oneshot
ExecStart=$SELF net
EOF
  cat >"$UNITDIR/$UNIT.timer" <<EOF
[Unit]
Description=obenhub: deadline of the paused RMAN cron line

[Timer]
OnCalendar=$(date -u -d "@$deadline" '+%Y-%m-%d %H:%M:%S UTC')
OnBootSec=5min
OnUnitInactiveSec=15min
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer" >/dev/null 2>&1
}
net_remove() {
  systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$UNITDIR/$UNIT.timer" "$UNITDIR/$UNIT.service"
  systemctl daemon-reload
}

do_restore() {
  local line="" cur new tmp npaused
  tmp=$(mktemp -d)
  cur=$tmp/cur new=$tmp/new
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp:?}'" RETURN
  cron_get "$cur" || return 1
  [ ! -s "$STATE/line" ] || line=$(cat "$STATE/line")
  npaused=$(grep -c -- "^$PREFIX" "$cur" || true)
  if [ -z "$line" ] && [ "$npaused" = 0 ]; then echo "nothing paused"; net_remove; rm -rf "${STATE:?}"; return 0; fi
  # un-prefix every paused line (dropped when its original is active already);
  # the saved line, when known, is appended if it is in neither form
  awk -v pre="$PREFIX" 'NR == FNR { if (substr($0, 1, length(pre)) != pre) act[$0] = 1; next }
    substr($0, 1, length(pre)) == pre { o = substr($0, length(pre) + 1); if (o in act) next; act[o] = 1; print o; next } { print }' "$cur" "$cur" >"$new"
  if [ -n "$line" ] && ! grep -Fxq -- "$line" "$new"; then
    printf '%s\n' "$line" >>"$new"
    echo "line was in neither form, appended"
  fi
  if cmp -s "$cur" "$new"; then
    echo "line already present"
  else
    cron_put <"$new"
    cron_get "$cur" || return 1
    cmp -s "$cur" "$new" || { echo "restore failed: the crontab read back differs from what was written" >&2; return 1; }
    echo "line restored"
  fi
  if grep -q -- "^$PREFIX" "$cur" || { [ -n "$line" ] && ! grep -Fxq -- "$line" "$cur"; }; then
    echo "restore failed: a paused line is left or the line is missing" >&2
    return 1
  fi
  net_remove
  if [ -s "$STATE/crontab.orig" ] && ! cmp -s "$STATE/crontab.orig" "$cur"; then
    echo "crontab differs from the saved copy"
    mv "$STATE" "$STATE.kept-$(date +%s)"
    echo "the saved copy is kept in $STATE.kept-*"
  else
    [ ! -s "$STATE/crontab.orig" ] || echo "crontab identical to the saved copy"
    rm -rf "${STATE:?}"
  fi
}

case ${1:-} in
  pause)
    sid=${2:?sid} kind=${3:?kind} deadline=${4:?deadline}
    [[ $sid =~ ^[A-Z0-9_]+$ && $kind =~ ^[a-z0-9]+$ && $deadline =~ ^[0-9]+$ ]] || { echo "bad arguments" >&2; exit 2; }
    [ ! -e "$STATE" ] || { echo "a pause is already active ($STATE exists)" >&2; exit 3; }
    tmp=$(mktemp -d)
    cur=$tmp/cur new=$tmp/new
    cron_get "$cur" || exit 1
    if grep -q -- "^$PREFIX" "$cur"; then echo "a paused line is already in the crontab: restore first" >&2; exit 5; fi
    pat="^[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [^ ]*rman-backup\\.sh $sid $kind # obenhub: $sid\$"
    n=$(grep -Ec -- "$pat" "$cur" || true)
    [ "$n" = 1 ] || { echo "expected exactly one managed $kind line for $sid, found $n" >&2; exit 4; }
    line=$(grep -E -- "$pat" "$cur")
    mkdir -p "$STATE"
    cp "$cur" "$STATE/crontab.orig"
    printf '%s\n' "$line" >"$STATE/line"
    printf '%s\n' "$deadline" >"$STATE/deadline"
    net_install "$deadline"
    P="$PREFIX" L="$line" awk '$0 == ENVIRON["L"] { print ENVIRON["P"] ENVIRON["L"]; next } { print }' "$cur" >"$new"
    cron_put <"$new"
    cron_get "$cur" || exit 1
    cmp -s "$cur" "$new" || { echo "pause failed: read-back differs" >&2; exit 1; }
    rm -rf "${tmp:?}"
    echo "paused: $line"
    ;;
  restore) do_restore ;;
  net)
    if [ ! -s "$STATE/deadline" ]; then do_restore; exit 0; fi
    if [ "$(date +%s)" -ge "$(cat "$STATE/deadline")" ]; then do_restore; else echo "before the deadline, nothing done"; fi
    ;;
  status)
    if [ -s "$STATE/line" ]; then echo "state: paused, deadline $(cat "$STATE/deadline")"; else echo "state: none"; fi
    echo "timer: $(systemctl is-enabled "$UNIT.timer" 2>/dev/null || true) / $(systemctl is-active "$UNIT.timer" 2>/dev/null || true)"
    tmp=$(mktemp -d)
    cron_get "$tmp/cur" || exit 1
    echo "paused lines in crontab: $(grep -c -- "^$PREFIX" "$tmp/cur" || true)"
    rm -rf "${tmp:?}"
    ;;
  *) echo "usage: $0 pause SID KIND DEADLINE | restore | net | status" >&2; exit 2 ;;
esac
