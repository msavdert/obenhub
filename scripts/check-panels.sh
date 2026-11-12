#!/usr/bin/env bash
# Run every panel query of a dashboard through Grafana's /api/ds/query and
# report the number of rows (data points or log lines) per panel. For
# dashboards without a template variable (lab/k8s cnpg.json, the shared host
# dashboard); the stage 3 and slice 1 scripts keep their own.
# A panel may be empty only if it reads a log datasource or its description
# starts with "Data only during a scenario" (the alert and fault panels).
# Needs the lab running.
# Usage: check-panels.sh <dashboard.json> <grafana-url> <env-file-with-GRAFANA_ADMIN_PASSWORD>
# Example: scripts/check-panels.sh lab/k8s/grafana/dashboards/cnpg.json http://127.0.0.1:43000 lab/k8s/mon/.env
set -euo pipefail

[ $# -eq 3 ] || { sed -n 9,10p "$0" >&2; exit 2; }
dashboard="$1"; grafana="$2"; envfile="$3"
pw="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$envfile")"
[ -n "$pw" ] || { echo "GRAFANA_ADMIN_PASSWORD missing from $envfile" >&2; exit 1; }

fail=0
n=$(jq '.panels | length' "$dashboard")
for i in $(seq 0 $((n - 1))); do
  [ "$(jq -r ".panels[$i].type" "$dashboard")" = row ] && continue
  title=$(jq -r ".panels[$i].title" "$dashboard")
  body=$(jq -c --argjson i "$i" '
    {queries: [.panels[$i].targets[] | . + {maxDataPoints: 500, intervalMs: 15000}
        | walk(if type == "string" then gsub("\\$__rate_interval"; "1m") else . end)],
     from: "now-1h", to: "now"}' "$dashboard")
  resp=$(curl -sS -u "admin:$pw" -H 'Content-Type: application/json' -d "$body" "$grafana/api/ds/query") || resp=""
  lines=$(printf '%s' "$resp" | jq -r --argjson i "$i" --slurpfile d "$dashboard" '
    ($d[0].panels[$i]) as $p
    | ($p.description // "" | startswith("Data only during a scenario")) as $scen
    | (.results // {}) as $r
    | $p.targets[] | .refId as $id | (.datasource.type // $p.datasource.type) as $t
    | ($r[$id]) as $v
    | if $v == null then "FAIL \($id): missing from the response"
      elif $v.error then "FAIL \($id): ERROR \($v.error)"
      else (($v.frames // []) | map((.data.values[0] // []) | length) | add // 0) as $n
        | if $n > 0 then "ok \($id): \($n) rows"
          elif $t == "victoriametrics-logs-datasource" or $scen then "empty (allowed) \($id): 0 rows"
          else "FAIL \($id): 0 rows" end
      end') || lines=""
  [ -n "$lines" ] || lines="FAIL unparsable response: $(printf '%s' "$resp" | head -c 200)"
  case "$lines" in *FAIL*) fail=1; status=FAIL;; *"empty (allowed)"*) status=empty;; *) status=ok;; esac
  printf '%-6s %-45s %s\n' "$status" "$title" "$(printf '%s' "$lines" | tr '\n' ';')"
done
exit "$fail"
