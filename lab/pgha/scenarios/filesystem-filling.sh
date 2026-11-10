#!/usr/bin/env bash
# Scenario filesystem-filling: fill the root filesystem of one replica until about 7 % of it is available (the share df shows as Avail), with one fallocate file, /var/tmp/obenhub-fill, sized from df at inject time. The 7 % target is below the 10 % threshold of HostFilesystemSpaceLow (lab/packs/host/rules.yml) and is refused if it would leave less than 1.5 GB free, so PostgreSQL on that replica keeps working. PostgreSQL's data directory is on the same filesystem. Inject first removes a file left on any node by a run that died without reverting. Revert removes the file and waits for a healthy cluster. Expect HostFilesystemSpaceLow for that node and nothing else.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FILL=/var/tmp/obenhub-fill
TARGET_SHARE=0.07
MIN_FREE=$((1500 * 1000 * 1000))
EXPECT=()
VICTIM=""
EXTRA_JSON=null

# share NODE: available / (available + used) of / in bytes, as the alert computes it
fs_share() { rn "$1" df -B1 --output=avail,used / | awk 'NR==2 {printf "%.4f", $1/($1+$2)}'; }

inject() {
  local avail used bytes
  # a file left by a run that died without its trap (SIGKILL, lost ssh)
  local n; for n in "${NODES[@]}"; do rn "$n" rm -f "$FILL"; done
  VICTIM=$(first_replica)
  [ -n "$VICTIM" ] || return 1
  read -r avail used < <(rn "$VICTIM" df -B1 --output=avail,used / | awk 'NR==2 {print $1, $2}')
  bytes=$(awk -v a="$avail" -v u="$used" -v t="$TARGET_SHARE" 'BEGIN{printf "%d", a - t*(a+u)}')
  [ "$bytes" -gt 0 ] && [ $((avail - bytes)) -ge "$MIN_FREE" ] || { log "refusing: $bytes bytes would leave $((avail - bytes)) free on $VICTIM"; return 1; }
  FILL_BYTES=$bytes
  SHARE_BEFORE=$(fs_share "$VICTIM")
  log "allocating $bytes bytes in $FILL on $VICTIM (available share $SHARE_BEFORE)"
  EXPECT=("HostFilesystemSpaceLow:$VICTIM")
  rn "$VICTIM" fallocate -l "$bytes" "$FILL" || return 1
  SHARE_AFTER=$(fs_share "$VICTIM")
  EXTRA_JSON=$(jq -n -c --arg v "$VICTIM" --argjson b "$bytes" --arg s0 "$SHARE_BEFORE" --arg s1 "$SHARE_AFTER" \
    '{victim: $v, bytes_allocated: $b, share_before: ($s0|tonumber), share_after: ($s1|tonumber)}')
  log "available share now $SHARE_AFTER"
}
after_detect() {
  [ "$(psql_n "$VICTIM" -c 'SELECT 1')" = 1 ] || { FAILS+=("PostgreSQL on $VICTIM not answering"); return 1; }
  log "PostgreSQL on $VICTIM still answers"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  rn "$VICTIM" rm -f "$FILL" || return 1
  wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario filesystem-filling
