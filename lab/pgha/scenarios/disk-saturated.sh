#!/usr/bin/env bash
# Scenario disk-saturated: on one replica, a transient systemd unit (obenhub-disksat) rewrites one 256 MiB file, /var/tmp/obenhub-disksat, with STREAMS parallel loops of `dd bs=1M oflag=direct conv=notrunc`, each over its own 4 MiB slice of the file, which keeps about 64 requests in flight on the disk under the root filesystem (inject waits for at least 20, twice the rule's 10, over 10 s and fails closed below it) (field 11 of /sys/block/<disk>/stat). The same filesystem holds PostgreSQL's data directory (checked: inject refuses if /var/tmp and /var/lib/postgresql are on different devices), and the disk is the whole disk under that filesystem, the kind of device HostDiskIOSaturation looks at (packs/host/rules.yml; inject refuses a device the rule's filter leaves out). The file never grows (one allocation of 256 MiB, overwritten) and inject refuses unless at least 4 GB stay free. fio is not installed on the VMs (checked 2026-11-27) and is not added; dd is. RuntimeMaxSec=3300 bounds a unit whose run died without reverting; it must exceed the inject wait plus DETECT_TIMEOUT plus HOLD_AFTER_DETECT plus the after_detect reads (worst case today about 2840 s), so raising DETECT_TIMEOUT or HOLD_AFTER_DETECT requires raising it. Inject first stops a leftover unit and removes a leftover file on every node (and refuses if that fails). Revert stops the unit and removes the file (retried for 180 s, and it fails if the unit is still active or the file still exists), then waits for a healthy cluster. HostDiskIOSaturation needs the 5 m rate of system.disk.weighted_io_time above 10 and then 30 m of "for", so detection takes about 32 minutes (attended dev run 2026-11-28: fired after 1916 s; nothing else fired, unexpected_alerts []). Expect HostDiskIOSaturation for that node; the first attended run (2026-11-28) needed no ALLOW entry (the queue may delay the replica's WAL replay and etcd's fsyncs on that node).
#
# Why not the other two disk signals (measured on pgha-2, sda, virtio, scheduler none, kernel 6.12, 2026-11-28,
# 20 s windows of /sys/block/sda/stat):
# - Share of busy time (system.disk.io_time, iostat %util): the client load alone holds 51 to 61 %; 1 MiB direct
#   writes at 1 to 64 streams give 52 to 77 %, 4k direct+dsync writes at 1 to 16 streams plateau at 86 to 90 %.
#   A multi-queue virtual disk never reaches 100 %, so a 90 % rule never fires and a lower one fires on load alone.
# - Average latency (system.disk.operation_time / system.disk.operations): flushes are not in it (gopsutil v4.26.10
#   reads /proc/diskstats fields 1 to 11), and 4k direct+dsync writes raise writes from 3.2 ms to only 4 to 6 ms,
#   below the labs' normal highest 5 m values (8.6 ms pgha, 14 to 60 ms oracle with fewer than 20 operations/s).
# - Queue depth (this rule): baseline 1.1 to 1.2 on pgha-2 (5 m highest in 11 days of VictoriaMetrics data 1.72 on
#   pgha, 1.92 on oracle), 18 at 16 streams of 1 MiB direct writes, 37 at 32, 62 at 64.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNIT=obenhub-disksat
FILE=/var/tmp/obenhub-disksat
FILE_MIB=256
STREAMS=64
MIN_DEPTH=20
MIN_FREE=$((4000 * 1000 * 1000))
# the device filter of HostDiskIOSaturation in packs/host/rules.yml, as an extended regex
DISK_RE='^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$'
DETECT_TIMEOUT=2700
EXPECT=()
VICTIM=""
DEV=""
EXTRA_JSON=null

# unload_node NODE: stop the unit, remove the file; status 0 only when the unit is not active and the
# file is gone ("unit not loaded" is fine, a failed rm or a unit that stays active is not)
unload_node() { rn "$1" sh -c "systemctl stop $UNIT 2>/dev/null; systemctl reset-failed $UNIT 2>/dev/null; rm -f $FILE; ! systemctl is-active --quiet $UNIT && ! test -e $FILE"; }
# a unit and a file left by a run that died without its trap (SIGKILL, lost ssh), on every node
clear_residue() { local n rc=0; for n in "${NODES[@]}"; do unload_node "$n" || rc=1; done; return $rc; }
# disk_of NODE PATH: the whole disk under the filesystem that holds PATH (the
# parent of a partition; the device itself when it has no parent); prints nothing on failure
disk_of() {
  local src p
  src=$(rn "$1" findmnt -no SOURCE -T "$2") || return 1
  [[ $src == /dev/* ]] || return 1
  p=$(rn "$1" lsblk -ndo PKNAME "$src") || return 1
  printf '%s' "${p:-${src#/dev/}}"
}
# queue_depth NODE DEVICE SECONDS: average number of requests in flight over the next SECONDS, whole number
# (field 11 of /sys/block/<device>/stat is milliseconds weighted by the requests in flight; the awk and sh run on the node)
# shellcheck disable=SC2016
queue_depth() { rn "$1" sh -c 'a=$(awk "{print \$11}" "/sys/block/$1/stat"); sleep "$2"; b=$(awk "{print \$11}" "/sys/block/$1/stat"); echo $(( (b - a) / ($2 * 1000) ))' sh "$2" "$3"; }
# disk_saturated: at least MIN_DEPTH requests in flight over 10 s; an empty or non-numeric answer (ssh failure) is not saturated
disk_saturated() { local d; d=$(queue_depth "$VICTIM" "$DEV" 10); [[ $d =~ ^[0-9]+$ ]] && [ "$d" -ge "$MIN_DEPTH" ]; }

inject() {
  local avail dev_pg
  clear_residue || { log "refusing: could not clear a leftover $UNIT unit or $FILE"; return 1; }
  VICTIM=$(first_replica)
  [ -n "$VICTIM" ] || return 1
  DEV=$(disk_of "$VICTIM" /var/tmp)
  dev_pg=$(disk_of "$VICTIM" /var/lib/postgresql)
  [[ $DEV =~ $DISK_RE ]] || { log "refusing: the disk under /var/tmp on $VICTIM is '$DEV', which HostDiskIOSaturation does not look at"; return 1; }
  [ "$DEV" = "$dev_pg" ] || { log "refusing: /var/tmp is on '$DEV' but /var/lib/postgresql on '$dev_pg' on $VICTIM"; return 1; }
  avail=$(rn "$VICTIM" df -B1 --output=avail /var/tmp | awk 'NR==2 {print $1}')
  [[ $avail =~ ^[0-9]+$ ]] && [ $((avail - FILE_MIB * 1024 * 1024)) -ge "$MIN_FREE" ] || { log "refusing: $avail bytes available in /var/tmp on $VICTIM, need $MIN_FREE after a ${FILE_MIB} MiB file"; return 1; }
  BOOT_BEFORE=$(boot_id "$VICTIM") && [ -n "$BOOT_BEFORE" ] || return 1
  DEPTH_BEFORE=$(queue_depth "$VICTIM" "$DEV" 10)
  [[ $DEPTH_BEFORE =~ ^[0-9]+$ ]] || return 1
  log "starting $UNIT on $VICTIM: $STREAMS streams of 1 MiB direct writes on $DEV (requests in flight before: $DEPTH_BEFORE, $avail bytes available)"
  EXPECT=("HostDiskIOSaturation:$VICTIM")
  # shellcheck disable=SC2016
  rn "$VICTIM" systemd-run --quiet --unit="$UNIT" -p RuntimeMaxSec=3300 \
    bash -c 'fallocate -l "$2M" "$1" || exit 1; n=$(($2 / $3)); for i in $(seq 0 $(($3 - 1))); do (while :; do dd if=/dev/zero of="$1" bs=1M count="$n" seek=$((i * n)) oflag=direct conv=notrunc status=none || exit 1; done) & done; wait -n; exit 1' sh "$FILE" "$FILE_MIB" "$STREAMS" || return 1
  wait_until 120 "disk saturated" disk_saturated || return 1
  log "disk $DEV on $VICTIM is saturated"
}
after_detect() {
  local boot_after depth lag reboot
  # an empty boot id (ssh failure) is unknown, never rebooted (lib.sh)
  boot_after=$(boot_id "$VICTIM")
  if [ -z "$boot_after" ]; then reboot=null; elif [ "$BOOT_BEFORE" = "$boot_after" ]; then reboot=false; else reboot=true; fi
  depth=$(queue_depth "$VICTIM" "$DEV" 10)
  # replay lag of the replicas on the leader, in bytes: the evidence for or against an ALLOW entry
  lag=$(psql_n "$(leader_name)" -d postgres -c "SELECT coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), 0)::bigint FROM pg_stat_replication")
  [[ $lag =~ ^[0-9]+$ ]] || lag=null
  [[ $depth =~ ^[0-9]+$ ]] || depth=null
  EXTRA_JSON=$(jq -n -c --arg v "$VICTIM" --arg d "$DEV" --argjson mib "$FILE_MIB" --argjson s "$STREAMS" --argjson q0 "$DEPTH_BEFORE" --argjson q1 "$depth" --argjson lag "$lag" \
    --argjson reboot "$reboot" \
    '{victim: $v, device: $d, file_mib: $mib, streams: $s, queue_depth_before: $q0, queue_depth_at_detect: $q1, max_replay_lag_bytes_at_detect: $lag, rebooted: $reboot}')
  [ "$reboot" != true ] || { FAILS+=("$VICTIM rebooted"); return 1; }
  [ "$(psql_n "$VICTIM" -c 'SELECT 1')" = 1 ] || { FAILS+=("PostgreSQL on $VICTIM not answering"); return 1; }
  log "PostgreSQL on $VICTIM answers; requests in flight $DEPTH_BEFORE -> $depth; replay lag $lag bytes; no reboot"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  wait_until 180 "disk load stopped and file removed on $VICTIM" unload_node "$VICTIM" || return 1
  wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario disk-saturated
