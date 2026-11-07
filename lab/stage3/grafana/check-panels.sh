#!/usr/bin/env bash
# Run every panel query of the dashboard through Grafana's /api/ds/query and
# report the number of rows (data points or log lines) per panel.
# Needs the lab running; the admin password comes from lab/stage3/.env.
# The dashboard has no variable; nodes are named in the legends.
# Usage: check-panels.sh
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
grafana="${GRAFANA:-http://127.0.0.1:23000}"
dashboard="$dir/dashboards/patroni.json"
pw="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$dir/../.env")"
[ -n "$pw" ] || { echo "GRAFANA_ADMIN_PASSWORD missing from lab/stage3/.env" >&2; exit 1; }

fail=0
n=$(jq '.panels | length' "$dashboard")
for i in $(seq 0 $((n - 1))); do
  title=$(jq -r ".panels[$i].title" "$dashboard")
  body=$(jq -c --argjson i "$i" '
    {queries: [.panels[$i].targets[] | . + {maxDataPoints: 500, intervalMs: 15000}
        | walk(if type == "string" then gsub("\\$__rate_interval"; "1m") else . end)],
     from: "now-1h", to: "now"}' "$dashboard")
  resp=$(curl -sS -u "admin:$pw" -H 'Content-Type: application/json' -d "$body" "$grafana/api/ds/query") || resp=""
  # one line per target refId: ok / empty (allowed) / FAIL, with the row count or error
  # empty is allowed only for log datasource targets (no errors in a healthy hour)
  lines=$(printf '%s' "$resp" | jq -r --argjson i "$i" --slurpfile d "$dashboard" '
    ($d[0].panels[$i]) as $p
    | (.results // {}) as $r
    | $p.targets[] | .refId as $id | (.datasource.type // $p.datasource.type) as $t
    | ($r[$id]) as $v
    | if $v == null then "FAIL \($id): missing from the response"
      elif $v.error then "FAIL \($id): ERROR \($v.error)"
      else (($v.frames // []) | map((.data.values[0] // []) | length) | add // 0) as $n
        | if $n > 0 then "ok \($id): \($n) rows"
          elif $t == "victoriametrics-logs-datasource" then "empty (allowed) \($id): 0 rows"
          else "FAIL \($id): 0 rows" end
      end') || lines=""
  if [ -z "$lines" ]; then
    lines="FAIL unparsable response: $(printf '%s' "$resp" | head -c 200)"
  fi
  case "$lines" in *FAIL*) fail=1; status=FAIL;; *"empty (allowed)"*) status=empty;; *) status=ok;; esac
  printf '%-6s %-45s %s\n' "$status" "$title" "$(printf '%s' "$lines" | tr '\n' ';')"
done
exit "$fail"
