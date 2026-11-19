#!/usr/bin/env bash
# Prove the shared Alertmanager grouping (lab/mon/alertmanager.yml) with a
# throwaway container: groups are per instance, a cluster-level alert forms one
# group per alertname, and nothing is inhibited (the config has no inhibit
# rules; suppression lives in the rule expressions).
# Needs docker and the prom/alertmanager image; no network after the pull.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab/mon" && pwd)"
name="obenhub-slice1-amtest-$$"
# Same image as the lab, read from the shared base so the pin lives in one place.
image="$(sed -n 's/^ *image: *\(prom\/alertmanager:[^ ]*\).*/\1/p' "$dir/compose.base.yaml" | head -n1)"
[ -n "$image" ] || { echo "alertmanager image not found in lab/mon/compose.base.yaml" >&2; exit 1; }
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$name" -p 127.0.0.1::9093 \
  -v "$dir/alertmanager.yml:/c.yml:ro" \
  "$image" --config.file=/c.yml --storage.path=/tmp >/dev/null
port="$(docker port "$name" 9093/tcp | head -n1 | sed 's/.*://')"
base="http://127.0.0.1:$port"

for _ in $(seq 1 30); do
  curl -fs "$base/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

post() {
  curl -fs -X POST "$base/api/v2/alerts" -H 'Content-Type: application/json' -d "$1" >/dev/null
}
alert() { # name instance
  if [ -n "${2:-}" ]; then
    printf '{"labels":{"alertname":"%s","service_instance_id":"%s"}}' "$1" "$2"
  else
    printf '{"labels":{"alertname":"%s"}}' "$1"
  fi
}

fail=0
check() { # description, python expression over `d` (list of groups) / `a` (alerts)
  local what="$1" expr="$2" json="$3"
  if python3 -I -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if ($expr) else 1)" <<<"$json"; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    fail=1
  fi
}

# 1. grouping per instance
post "[$(alert PostgresReplayBacklog pg-primary),$(alert PostgresReplayBacklog pg-standby)]"
sleep 2
groups="$(curl -fs "$base/api/v2/alerts/groups")"
check "PostgresReplayBacklog forms one group per instance" \
  "sorted(g['labels'].get('service_instance_id') for g in d if g['labels']['alertname']=='PostgresReplayBacklog') == ['pg-primary','pg-standby']" "$groups"

# 2. a cluster-level alert has its own group, and nothing is inhibited
post "[$(alert CollectorAbsent),$(alert PostgresTargetAbsent pg-standby),$(alert PostgresSeriesVanished pg-standby)]"
sleep 2
groups="$(curl -fs "$base/api/v2/alerts/groups")"
check "CollectorAbsent without an instance forms one group" \
  "[g['labels'] for g in d if g['labels']['alertname']=='CollectorAbsent'] == [{'alertname':'CollectorAbsent'}]" "$groups"
alerts="$(curl -fs "$base/api/v2/alerts")"
check "no alert is inhibited" \
  "all(not x['status']['inhibitedBy'] for x in d)" "$alerts"

exit "$fail"
