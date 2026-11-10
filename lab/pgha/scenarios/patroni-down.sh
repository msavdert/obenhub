#!/usr/bin/env bash
# Scenario patroni-down: make one replica's Patroni REST API unreachable for the local Collector only, while its PostgreSQL keeps running and the other nodes still reach Patroni. The block is an nftables table "inet obenhub_fault" on that replica with one rule in the output hook: drop tcp dport 8008 from the uid of the otelcol-contrib user (the Collector scrapes the node's own address, lab/pgha/files/otelcol.yaml.tmpl). Revert deletes the table. Stopping Patroni itself is not an option: its hardware watchdog (mode required) resets the VM. Needs nftables on the node (provision.sh). Expect PatroniTargetAbsent for that node and nothing else.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
VICTIM=""
inject() {
  VICTIM=$(first_replica)
  [ -n "$VICTIM" ] || return 1
  log "blocking Patroni REST (8008) on $VICTIM for the Collector (uid otelcol-contrib)"
  EXPECT=("PatroniTargetAbsent:$VICTIM")
  fault_table_add "$VICTIM" <<'NFT'
table inet obenhub_fault {
  chain out {
    type filter hook output priority 0; policy accept;
    meta skuid "otelcol-contrib" tcp dport 8008 counter drop
  }
}
NFT
}
after_detect() {
  # PostgreSQL on the victim kept running: the point of the scenario
  [ "$(psql_n "$VICTIM" -c 'SELECT 1')" = 1 ] || { FAILS+=("PostgreSQL on $VICTIM not answering"); return 1; }
  log "PostgreSQL on $VICTIM still answers"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  fault_table_del "$VICTIM" || return 1
  wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario patroni-down
