#!/usr/bin/env bash
# Prove Alertmanager grouping and inhibition with a throwaway container:
# groups are per instance, and an inhibit rule only mutes the same instance.
# Needs docker and the prom/alertmanager image; no network after the pull.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="obenhub-slice1-amtest-$$"
# Same image as the lab, read from compose.yaml so the pin lives in one place.
image="$(sed -n 's/^ *image: *\(prom\/alertmanager:[^ ]*\).*/\1/p' "$dir/../compose.yaml" | head -n1)"
[ -n "$image" ] || { echo "alertmanager image not found in compose.yaml" >&2; exit 1; }
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
post "[$(alert ReplayBacklog pg-primary),$(alert ReplayBacklog pg-standby)]"
sleep 2
groups="$(curl -fs "$base/api/v2/alerts/groups")"
check "ReplayBacklog forms one group per instance" \
  "sorted(g['labels'].get('service_instance_id') for g in d if g['labels']['alertname']=='ReplayBacklog') == ['pg-primary','pg-standby']" "$groups"

# 2. per-instance inhibition: standby target absent mutes only standby series
post "[$(alert PostgresTargetAbsent pg-standby),$(alert SeriesVanished pg-standby),$(alert SeriesVanished pg-primary)]"
sleep 2
alerts="$(curl -fs "$base/api/v2/alerts")"
inhibited='lambda n, i: [x for x in d if x["labels"]["alertname"]==n and x["labels"].get("service_instance_id")==i][0]["status"]["inhibitedBy"]'
check "SeriesVanished on the standby is inhibited by its own PostgresTargetAbsent" \
  "bool(($inhibited)('SeriesVanished','pg-standby'))" "$alerts"
check "SeriesVanished on the primary is NOT inhibited" \
  "not ($inhibited)('SeriesVanished','pg-primary')" "$alerts"
check "PostgresTargetAbsent itself is not inhibited" \
  "not ($inhibited)('PostgresTargetAbsent','pg-standby')" "$alerts"

# 3. a dead Collector mutes every target and series alert
post "[$(alert CollectorAbsent)]"
sleep 2
alerts="$(curl -fs "$base/api/v2/alerts")"
check "CollectorAbsent mutes PostgresTargetAbsent" \
  "bool(($inhibited)('PostgresTargetAbsent','pg-standby'))" "$alerts"
check "CollectorAbsent mutes SeriesVanished on the primary" \
  "bool(($inhibited)('SeriesVanished','pg-primary'))" "$alerts"
check "ReplayBacklog is never inhibited" \
  "not ($inhibited)('ReplayBacklog','pg-primary')" "$alerts"

exit "$fail"
