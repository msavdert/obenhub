#!/usr/bin/env bash
# Scenario repl-cut: disconnect the standby from the repl network; expect StandbyNotStreaming for pg-standby.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("StandbyNotStreaming:pg-standby")
STANDBY_IP=""
inject() {
  STANDBY_IP=$(docker inspect "$STANDBY" --format "{{(index .NetworkSettings.Networks \"$REPL_NET\").IPAddress}}")
  [ -n "$STANDBY_IP" ] || return 1
  docker network disconnect "$REPL_NET" "$STANDBY"
}
revert() {
  # nothing to undo if the disconnect never happened
  [ -n "$STANDBY_IP" ] || return 0
  if [ -z "$(docker inspect "$STANDBY" --format "{{with index .NetworkSettings.Networks \"$REPL_NET\"}}x{{end}}")" ]; then
    docker network connect --ip "$STANDBY_IP" "$REPL_NET" "$STANDBY" || return 1
  fi
  wait_until 180 "standby streaming again" is_streaming
}
run_scenario repl-cut
