#!/usr/bin/env bash
# Scenario logical-cut: disconnect the subscriber from the logical network; expect PostgresLogicalSubscriptionNotStreaming for pg-subscriber. PostgresLogicalSlotStalled is not expected: the slot only turns inactive about 60 s (wal_sender_timeout) after the cut and the rule needs 3 m inactive plus a 1 m hold, while the scenario reverts as soon as the first alert is delivered. If it did fire, the run fails as unexpected.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PostgresLogicalSubscriptionNotStreaming:pg-subscriber")
SUBSCRIBER_IP=""
inject() {
  SUBSCRIBER_IP=$(docker inspect "$SUBSCRIBER" --format "{{(index .NetworkSettings.Networks \"$LOGICAL_NET\").IPAddress}}")
  [ -n "$SUBSCRIBER_IP" ] || return 1
  docker network disconnect "$LOGICAL_NET" "$SUBSCRIBER"
}
revert() {
  # nothing to undo if the disconnect never happened
  [ -n "$SUBSCRIBER_IP" ] || return 0
  if [ -z "$(docker inspect "$SUBSCRIBER" --format "{{with index .NetworkSettings.Networks \"$LOGICAL_NET\"}}x{{end}}")" ]; then
    docker network connect --ip "$SUBSCRIBER_IP" "$LOGICAL_NET" "$SUBSCRIBER" || return 1
  fi
  wait_until 180 "logical replication streaming again" logical_streaming
}
run_scenario logical-cut
