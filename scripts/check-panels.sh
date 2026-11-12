#!/usr/bin/env bash
# Run every panel query of a dashboard through Grafana's /api/ds/query and
# report the number of rows (data points or log lines) per panel. Panels
# inside collapsed rows are checked too. One script for all labs; the
# lab:<lab>:panels mise tasks call it.
# A panel may be empty only if it reads a log datasource, or its description
# starts with "Data only during a scenario" (alert and fault panels), or it
# sits in a row whose title contains "(labs with": such a row holds the
# panels of a component only some labs run (PgBouncer, a logical subscriber).
# --strict-rows turns the last exception off, for a lab that runs the component.
# An optional fourth argument replaces $instance (the PostgreSQL dashboard's
# variable) in the queries. Needs the lab running.
# Usage: check-panels.sh [--strict-rows] <dashboard.json> <grafana-url> <env-file-with-GRAFANA_ADMIN_PASSWORD> [instance]
# Example: scripts/check-panels.sh lab/k8s/grafana/dashboards/cnpg.json http://127.0.0.1:43000 lab/k8s/mon/.env
set -euo pipefail

strict=false
if [ "${1:-}" = "--strict-rows" ]; then strict=true; shift; fi
[ $# -ge 3 ] && [ $# -le 4 ] || { sed -n 13,14p "$0" >&2; exit 2; }
dashboard="$1"; grafana="$2"; envfile="$3"; instance="${4:-}"
pw="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$envfile")"
[ -n "$pw" ] || { echo "GRAFANA_ADMIN_PASSWORD missing from $envfile" >&2; exit 1; }
# curl --config reads the value in double quotes with backslash escapes (curl man page, --config)
cfgpw=${pw//\\/\\\\}; cfgpw=${cfgpw//\"/\\\"}

# top-level panels plus the panels of rows, each tagged with its row title
flat="$(mktemp)"
trap 'rm -f "$flat"' EXIT
jq '[.panels[] as $p | if $p.type == "row" then ($p.panels // [])[] | . + {rowTitle: $p.title} else $p end]' "$dashboard" >"$flat"

fail=0
n=$(jq 'length' "$flat")
for i in $(seq 0 $((n - 1))); do
  title=$(jq -r ".[$i].title" "$flat")
  body=$(jq -c --argjson i "$i" --arg inst "$instance" '
    {queries: [.[$i].targets[] | . + {maxDataPoints: 500, intervalMs: 15000}
        | walk(if type == "string" then gsub("\\$__rate_interval"; "1m") | (if $inst != "" then gsub("\\$instance"; $inst) else . end) else . end)],
     from: "now-1h", to: "now"}' "$flat")
  resp=$(curl -sS --connect-timeout 5 --max-time 60 -K <(printf 'user = "admin:%s"\n' "$cfgpw") -H 'Content-Type: application/json' -d "$body" "$grafana/api/ds/query") || resp=""
  lines=$(printf '%s' "$resp" | jq -r --argjson i "$i" --argjson strict "$strict" --slurpfile d "$flat" '
    ($d[0][$i]) as $p
    | ($p.description // "" | startswith("Data only during a scenario")) as $scen
    | ((($p.rowTitle // "") | contains("(labs with")) and ($strict | not)) as $optrow
    | (.results // {}) as $r
    | $p.targets[] | .refId as $id | (.datasource.type // $p.datasource.type) as $t
    | ($r[$id]) as $v
    | if $v == null then "FAIL \($id): missing from the response"
      elif $v.error then "FAIL \($id): ERROR \($v.error)"
      else (($v.frames // []) | map((.data.values[0] // []) | length) | add // 0) as $n
        | if $n > 0 then "ok \($id): \($n) rows"
          elif $t == "victoriametrics-logs-datasource" or $scen or $optrow then "empty (allowed) \($id): 0 rows"
          else "FAIL \($id): 0 rows" end
      end') || lines=""
  [ -n "$lines" ] || lines="FAIL unparsable response: $(printf '%s' "$resp" | head -c 200)"
  case "$lines" in *FAIL*) fail=1; status=FAIL;; *"empty (allowed)"*) status=empty;; *) status=ok;; esac
  printf '%-6s %-45s %s\n' "$status" "$title" "$(printf '%s' "$lines" | tr '\n' ';')"
done
exit "$fail"
