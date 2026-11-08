#!/usr/bin/env bash
# Scenario patroni-down: make one replica's Patroni REST API unreachable for the Collector only, while its PostgreSQL keeps running and the other nodes still reach Patroni. The block is one iptables DROP rule per Collector address, inside the replica container's own network namespace (nsenter, sudo); nothing at host level changes. Stopping Patroni itself is not possible here: Patroni is PID 1 in the node containers (entrypoint.sh execs it), so stopping it stops the container and PostgreSQL with it; the scenario blocks the Collector's scrape instead. Needs passwordless sudo, nsenter and iptables on the Docker host. Expect PatroniTargetAbsent for that node and nothing else.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
VICTIM="" PID="" IPS=()
block() { # ACTION (-I or -D)
  local ip rc=0
  for ip in "${IPS[@]}"; do
    sudo nsenter -t "$PID" -n iptables "$1" INPUT -p tcp --dport 8008 -s "$ip" -j DROP || rc=1
  done
  return $rc
}
inject() {
  VICTIM=$(first_replica)
  [ -n "$VICTIM" ] || return 1
  PID=$(docker inspect -f '{{.State.Pid}}' "$(cname "$VICTIM")")
  mapfile -t IPS < <(docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' "$(cname otelcol)" | grep .)
  [ -n "$PID" ] && [ "${#IPS[@]}" -gt 0 ] || return 1
  log "blocking Patroni REST (8008) on $VICTIM for the Collector (${IPS[*]})"
  EXPECT=("PatroniTargetAbsent:$VICTIM")
  block -I
}
after_detect() {
  # PostgreSQL on the victim kept running: the point of the scenario
  [ "$(psql_n "$VICTIM" -c 'SELECT 1')" = 1 ] || { FAILS+=("PostgreSQL on $VICTIM not answering"); return 1; }
  log "PostgreSQL on $VICTIM still answers"
}
revert() {
  [ -n "$VICTIM" ] || return 0
  block -D || return 1
  wait_until 120 "cluster healthy" cluster_healthy
}
run_scenario patroni-down
