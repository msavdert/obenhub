#!/usr/bin/env bash
# Scenario memory-pressure: on one replica, a Python process (systemd unit obenhub-memhog) writes every page of a buffer sized so that MemAvailable falls to about 6 % of MemTotal, and holds it. The size comes from MemAvailable at inject time. The unit has OOMScoreAdjust=1000 and MemoryMax=size+256 MiB so that the hog, not PostgreSQL, Patroni, etcd or the Collector, is the OOM victim; Patroni's hardware watchdog (mode required) resets the VM if Patroni is frozen for about 20 s, so this scenario checks that the victim's boot id is unchanged and records oom_kill from /proc/vmstat before and after. RuntimeMaxSec=1800 (above the default inject wait plus DETECT_TIMEOUT; raise it with longer DETECT_TIMEOUT or HOLD_AFTER_DETECT) bounds a hog whose run died without reverting, and inject first stops a leftover unit on every node. Revert stops the unit. Expect HostMemoryAvailableLow for that node and nothing else.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNIT=obenhub-memhog
TARGET_SHARE=0.06
MARGIN=$((256 * 1024 * 1024))
EXPECT=()
VICTIM=""
EXTRA_JSON=null

# the awk programs run on the node (rn quotes them), not in this shell
# shellcheck disable=SC2016
memkb() { rn "$1" awk -v k="$2" '$1 == k":" {print $2}' /proc/meminfo; }
# shellcheck disable=SC2016
oom_kills() { rn "$1" awk '$1 == "oom_kill" {print $2}' /proc/vmstat; }
boot_id() { rn "$1" cat /proc/sys/kernel/random/boot_id; }
# avail_share NODE: MemAvailable / MemTotal
# prints nothing unless both values were read (an ssh failure must not read as 0)
avail_share() { local a t; a=$(memkb "$1" MemAvailable); t=$(memkb "$1" MemTotal); [[ $a =~ ^[0-9]+$ && $t =~ ^[1-9][0-9]*$ ]] || return 1; awk -v a="$a" -v t="$t" 'BEGIN{printf "%.4f", a/t}'; }
# an empty or non-numeric share (ssh failure) never counts as resident
hog_resident() { local s; s=$(avail_share "$VICTIM"); [[ $s =~ ^[0-9]+\.[0-9]+$ ]] && awk -v s="$s" 'BEGIN{exit !(s <= 0.08)}'; }
# a hog left by a run that died without its trap (SIGKILL, lost ssh)
clear_residue() { local n; for n in "${NODES[@]}"; do rn "$n" sh -c "systemctl stop $UNIT 2>/dev/null; systemctl reset-failed $UNIT 2>/dev/null; true"; done; }

inject() {
  local avail total bytes
  clear_residue
  VICTIM=$(first_replica)
  [ -n "$VICTIM" ] || return 1
  avail=$(($(memkb "$VICTIM" MemAvailable) * 1024))
  total=$(($(memkb "$VICTIM" MemTotal) * 1024))
  bytes=$(awk -v a="$avail" -v t="$total" -v s="$TARGET_SHARE" 'BEGIN{printf "%d", a - s*t}')
  [ "$bytes" -gt 0 ] || return 1
  BOOT_BEFORE=$(boot_id "$VICTIM"); OOM_BEFORE=$(oom_kills "$VICTIM"); SHARE_BEFORE=$(avail_share "$VICTIM")
  HOG_BYTES=$bytes
  log "starting $UNIT on $VICTIM: $bytes bytes (MemAvailable share $SHARE_BEFORE)"
  EXPECT=("HostMemoryAvailableLow:$VICTIM")
  # bytes([1]) * n is one allocation filled with a non-zero byte: every page is written
  rn "$VICTIM" systemd-run --quiet --unit="$UNIT" -p OOMScoreAdjust=1000 -p RuntimeMaxSec=1800 -p "MemoryMax=$((bytes + MARGIN))" \
    python3 -c 'import sys, time; b = bytes([1]) * int(sys.argv[1]); time.sleep(86400)' "$bytes" || return 1
  wait_until 120 "memory resident" hog_resident || return 1
  SHARE_AFTER=$(avail_share "$VICTIM")
  log "MemAvailable share now $SHARE_AFTER"
}
after_detect() {
  local oom_after boot_after
  oom_after=$(oom_kills "$VICTIM"); boot_after=$(boot_id "$VICTIM")
  EXTRA_JSON=$(jq -n -c --arg v "$VICTIM" --argjson b "$HOG_BYTES" --arg s0 "$SHARE_BEFORE" --arg s1 "$(avail_share "$VICTIM")" \
    --argjson o0 "$OOM_BEFORE" --argjson o1 "$oom_after" --argjson reboot "$([ "$BOOT_BEFORE" = "$boot_after" ] && echo false || echo true)" \
    --arg hog "$(rn "$VICTIM" systemctl is-active "$UNIT" 2>/dev/null)" \
    '{victim: $v, bytes_held: $b, share_before: ($s0|tonumber), share_at_detect: ($s1|tonumber), oom_kill_before: $o0, oom_kill_after: $o1, rebooted: $reboot, hog_unit_state: $hog}')
  [ "$BOOT_BEFORE" = "$boot_after" ] || { FAILS+=("$VICTIM rebooted"); return 1; }
  [ "$(psql_n "$VICTIM" -c 'SELECT 1')" = 1 ] || { FAILS+=("PostgreSQL on $VICTIM not answering"); return 1; }
  log "PostgreSQL on $VICTIM answers; oom_kill $OOM_BEFORE -> $oom_after; no reboot"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  rn "$VICTIM" sh -c "systemctl stop $UNIT 2>/dev/null; systemctl reset-failed $UNIT 2>/dev/null; true"
  wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario memory-pressure
