#!/usr/bin/env bash
# Scenario replica-not-eligible: cut one replica from the leader's PostgreSQL port and write about 100 MB on the leader, beyond maximum_lag_on_failover (16 MiB). The cut is an nftables table "inet obenhub_fault" on the replica that drops tcp 5432 to and from the leader's address (its WAL receiver stops; its DCS session, Patroni REST and monitoring stay). Revert deletes the table. Needs nftables on the node (provision.sh). Expect PatroniReplicaNotEligible on that replica; its StandbyNotStreaming follows once the WAL receiver has timed out.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R="" L="" CUT=0
inject() {
  local lip
  R=$(first_replica) && [ -n "$R" ] || return 1
  L=$(leader_name) && [ -n "$L" ] || return 1
  lip=$(node_ip "$L") || return 1
  EXPECT=("PatroniReplicaNotEligible:$R" "StandbyNotStreaming:$R")
  CUT=1
  fault_table_add "$R" <<NFT || return 1
table inet obenhub_fault {
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr $lip tcp dport 5432 counter drop
  }
  chain in {
    type filter hook input priority 0; policy accept;
    ip saddr $lip tcp sport 5432 counter drop
  }
}
NFT
  psql_n "$L" -c "DROP TABLE IF EXISTS s3_scratch; CREATE TABLE s3_scratch AS SELECT g, md5(g::text) || md5((g+1)::text) AS pad FROM generate_series(1, 1500000) g;" >/dev/null || return 1
  log "replica $R cut from $L:5432; leader $L wrote the scratch table"
}
revert() {
  local rc=0
  if [ "$CUT" = 1 ]; then fault_table_del "$R" || rc=1; fi
  [ -n "$L" ] && psql_n "$(leader_or "$L")" -c "DROP TABLE IF EXISTS s3_scratch" >/dev/null 2>&1
  wait_until 300 "cluster healthy again" cluster_healthy || rc=1
  return $rc
}
run_scenario replica-not-eligible
