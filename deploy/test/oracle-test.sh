#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install test of docs/guides/monitor/oracle.md (roadmap G3): the backend of
# deploy/compose, a Collector as a container with the oracledb-dg and
# oracledb-backup fragments, and an Oracle Database Free 26ai container that no
# lab script provisioned. The monitoring users come from
# deploy/oracle/monitoring-user.sql, applied as the page says. It asserts
# that the heartbeat is there, that nothing but Watchdog fires once the longest
# `for:` has elapsed, that the dead-man route delivers Watchdog about every
# 60 s, and that the panels of the Oracle dashboard have data or are empty for
# a named reason. One JSON line per run goes to deploy/results/runs.jsonl.
# Needs docker, jq, curl, openssl and about 4 GiB of free memory; takes about
# 25 minutes. Not part of `mise run check`.
#   mise run deploy:oracle-test
# Environment: ORACLE_TEST_PORT_BASE (default 61300; six ports from there are
# bound on 127.0.0.1), ORACLE_TEST_EVIDENCE=0 to skip the runs.jsonl line,
# ORACLE_TEST_SETTLE=<seconds> to shorten the settle while debugging the test
# (no evidence line is written then).
#
# The image. container-registry.oracle.com/database/free is pulled for this
# test only, by digest, as a target the test runs against; its terms and why they
# are no problem for the repository: "Licence of the test image" in
# docs/guides/monitor/oracle.md.
#
# Refusals (exit 2, nothing changed): a missing tool, a port in use, less
# than ORACLE_TEST_MIN_MEM_MIB (4096) of MemAvailable, a container, network or
# volume of this test's name, or any container or volume of its compose project,
# already there.
#
# Settle: the longest `for:` of the collector and oracledb-dg packs (settle_packs
# of lib.sh) plus a margin. The oracledb-backup pack is left out of the wait
# because OracleBackupMissing (for: 30m) cannot fire here: the test takes one RMAN
# backup before the Collector starts, and asserts below that the rule's own
# expression is empty (the primary has a backup.age series of kind database).
#
# Expected empty, and why (listed in the line's panels_empty_titles):
#  - standby lag, lag data age, redo apply and archive gap panels: the database
#    has no standby; the DG pack's queries that read a standby return no rows
#    by design (packs/oracledb-dg/queries.yaml). The fast-start failover panels
#    have data: the queries return DISABLED and 0 on a database without a broker.
#  - the recovery area panel: the Free image sets no db_recovery_file_dest
#    (read in the container), so V$RECOVERY_FILE_DEST has no row.
#  - the alert log pipeline is not run: the log is inside the Oracle container
#    (owner oracle, mode 640) and the Collector of this test is another
#    container; OBENHUB_ORACLE_ALERT_LOG points at a path that does not exist.
# shellcheck disable=SC2329  # functions are called from the EXIT trap and settle_wait
set -euo pipefail

# shellcheck source=deploy/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_NAME=oracle-test
project=obenhub-oracle-test
net="$project-db"
mon="${project}_mon"
orac="$project-ora"
colc="$project-otelcol"
# Oracle AI Database 26ai Free, the manifest list digest of tag `latest` read on
# 2026-11-27 (image label version 23.26.0; the database reports 23.26.4.0.0)
ORACLE_IMAGE=container-registry.oracle.com/database/free@sha256:f5a1791bf5628fd1a97e07584ff5ac5537da5021c23e70f5083f48c8fcd6476e
# the Collector runs the image of the gateway, as deploy/README.md asks
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' "$repo/deploy/compose/compose.yaml")"
[ -n "$OTELCOL_IMAGE" ] || { echo "oracle-test: gateway image not found in compose.yaml" >&2; exit 2; }

# --- refusals, before anything is created --------------------------------------
for tool in docker jq curl openssl ss yq; do
  command -v "$tool" >/dev/null || { echo "oracle-test: $tool not found" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo "oracle-test: docker is not reachable" >&2; exit 2; }
avail_mib=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
min_mib=${ORACLE_TEST_MIN_MEM_MIB:-4096}
[ "${avail_mib:-0}" -ge "$min_mib" ] || { echo "oracle-test: MemAvailable ${avail_mib:-?} MiB is below $min_mib MiB (Oracle Free needs about 2 GiB for the instance, assumption: twice that for headroom)" >&2; exit 2; }
for c in "$orac" "$colc"; do
  if docker ps -a --format '{{.Names}}' | grep -x "$c" >/dev/null; then echo "oracle-test: container $c exists (a leftover?); remove it first" >&2; exit 2; fi
done
if docker network ls --format '{{.Name}}' | grep -E "^($net|$mon)\$" >/dev/null; then echo "oracle-test: network $net or $mon exists; remove it first" >&2; exit 2; fi
leftover=$( { docker ps -aq --filter "label=com.docker.compose.project=$project"; docker volume ls -q --filter "label=com.docker.compose.project=$project"; docker volume ls -q | grep "^${project}[_-]" || true; } | sort -u | head -3)
[ -z "$leftover" ] || { echo "oracle-test: containers or volumes of compose project $project exist (e.g. $(echo "$leftover" | head -1)); remove them first" >&2; exit 2; }

base="${ORACLE_TEST_PORT_BASE:-61300}"
p_grafana=$base p_vm=$((base + 1)) p_vl=$((base + 2)) p_vmalert=$((base + 3)) p_am=$((base + 4)) p_gw=$((base + 5))
lib_check_ports "set ORACLE_TEST_PORT_BASE"

lib_init
EVIDENCE_IMAGES="$ORACLE_IMAGE $OTELCOL_IMAGE"
settle_packs="collector oracledb-dg"
hb_metric=oracledb.collection.heartbeat
hb_matcher='"service.instance.id"="FREE","obenhub.cluster.name"="free"'
ora_mem_mib=0 ora_banner="" ora_ready_s=0

teardown() {
  set +e
  docker rm -fv "$colc" "$orac" >/dev/null 2>&1
  backend_down
  docker network rm "$net" >/dev/null 2>&1
  tmp_remove
}
collector_alive() { docker ps -q -f name="^$colc\$" | grep -q .; }
collector_diag() { docker logs --tail 30 "$colc"; }
# sql <sqlplus args...>: sqlplus inside the Oracle container; the statements come on stdin
sql() { docker exec -i "$orac" sqlplus -s -L "$@"; }

# (grep -q would end the pipe early and, under pipefail, fail the test on SIGPIPE: grep to /dev/null instead)
# a. fresh state: certificates, .env, compose project (the repo checkout stays clean)
log "licence: the Oracle Free image is pulled for this test only, under the Oracle Free Use Terms and Conditions (/licenses/license.txt in the image)"
# the inventory of the page: this install expects the Oracle target, not the example's PostgreSQL;
# written before compose up (backend_prepare of lib.sh), so the example's pg-1 is never expected
# (the page edits it in place and reloads vmalert instead)
backend_prepare() {
cat >"$cdir/inventory.yml" <<'YAML'
groups:
  - name: inventory
    interval: 15s
    rules:
      - record: obenhub.expected_collector
        expr: |
          union(
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-gateway"),
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-host-1", "obenhub.upstream", "otelcol-gateway")
          )

      - record: obenhub.expected_target
        expr: label_set(vector(1), "service.namespace", "obenhub", "service.name", "oracledb", "obenhub.cluster.name", "free", "service.instance.id", "FREE", "obenhub.collector", "otelcol-host-1")
YAML
}
backend_up gateway

# b. Oracle Database Free: own network, default settings, no lab file
log "oracle: pull and start $ORACLE_IMAGE"
docker image inspect "$ORACLE_IMAGE" >/dev/null 2>&1 || docker pull -q "$ORACLE_IMAGE" >/dev/null
docker network create "$net" >/dev/null
syspw="$(openssl rand -hex 12)"
t_ora=$(date +%s)
docker run -d --name "$orac" --network "$net" --network-alias ora --env-file <(printf 'ORACLE_PWD=%s\n' "$syspw") "$ORACLE_IMAGE" >/dev/null
for _ in $(seq 300); do
  docker logs "$orac" 2>&1 | grep 'DATABASE IS READY TO USE!' >/dev/null && break
  [ -n "$(docker ps -q -f name="^$orac\$")" ] || { docker logs --tail 20 "$orac" >&2; fail "Oracle container exited"; break; }
  sleep 5
done
ora_ready_s=$(( $(date +%s) - t_ora ))
docker logs "$orac" 2>&1 | grep 'DATABASE IS READY TO USE!' >/dev/null || fail "Oracle not ready after ${ora_ready_s}s"
log "oracle: ready after ${ora_ready_s}s"
ora_banner=$(sql / as sysdba <<<"set head off feedback off pages 0 lines 300
select banner_full from v\$version fetch first 1 rows only;" | tr -s ' \n' ' ' | sed 's/ *$//')
log "oracle: $ora_banner"

# c. the users, as the page says: the script into the container, passwords on stdin
monpw="$(openssl rand -hex 12)"
dgpw="$(openssl rand -hex 12)"
docker cp "$repo/deploy/oracle/monitoring-user.sql" "$orac:/tmp/monitoring-user.sql"
printf '%s\n%s\n' "$monpw" "$dgpw" | sql / as sysdba @/tmp/monitoring-user.sql >"$tmp/user.log" 2>&1 \
  || { cat "$tmp/user.log" >&2; fail "monitoring-user.sql"; }
cat "$tmp/user.log"
# SYSDG logins are checked against the password file (monitoring-user.sql header)
# shellcheck disable=SC2016  # $ in the SQL is Oracle's, not the shell's
pwf=$(sql / as sysdba <<<"set head off feedback off pages 0
select value from v\$parameter where name = 'remote_login_passwordfile';" | tr -d ' \n')
log "oracle: remote_login_passwordfile = $pwf"
# the logins the page checks, with the connect statement on stdin (a password on the command line shows in ps):
# the SYSDG user, and the monitoring user sees every container
# shellcheck disable=SC2016  # $ in the SQL is Oracle's, not the shell's
out=$(printf 'connect "C##OBENHUB_DG"/"%s"@//localhost:1521/FREE as sysdg\nset head off feedback off pages 0\nselect database_role from v$database;\n' "$dgpw" | sql /nolog) || out=""
[ "$(tr -d ' \n' <<<"$out")" = PRIMARY ] || fail "login of C##OBENHUB_DG as sysdg: [$out]"
# shellcheck disable=SC2016
out=$(printf 'connect "C##OBENHUB_MON"/"%s"@//localhost:1521/FREE\nset head off feedback off pages 0\nselect (select count(distinct con_id) from v$con_sysstat) || chr(32) || (select count(*) from v$containers) from dual;\n' "$monpw" | sql /nolog) || out=""
read -r seen all <<<"$out" || true
{ [ "${seen:-}" = "${all:-x}" ] && [ "${seen:-0}" -ge 1 ]; } || fail "C##OBENHUB_MON sees [$out] containers in V\$CON_SYSSTAT and V\$CONTAINERS, want equal"
log "oracle: users ok (C##OBENHUB_MON sees ${seen:-?} containers)"

# d. one online RMAN backup: the image runs ARCHIVELOG with no recovery area, so the
# backup lands in \$ORACLE_HOME/dbs; without one OracleBackupMissing fires after 30 minutes
docker exec -i "$orac" rman target / >"$tmp/rman.log" 2>&1 <<<"backup database;" || { tail -20 "$tmp/rman.log" >&2; fail "rman backup database"; }
log "oracle: RMAN backup done"

# e. Collector: files as /etc/otelcol-contrib, as the page lays them out
oc="$tmp/otelcol"
install -d "$oc/packs" "$oc/tls"
cp "$repo/packs/otelcol-base.yaml" "$oc/packs/"
for p in collector oracledb-dg oracledb-backup; do cp -r "$repo/packs/$p" "$oc/packs/"; done
cp "$repo/deploy/collector/otelcol-tls.yaml" "$oc/"
cp "$repo/deploy/collector/obenhub-oracle.env.example" "$oc/obenhub.env"
cp "$cdir/tls/ca.crt" "$cdir/tls/client.crt" "$cdir/tls/client.key" "$oc/tls/"
chmod 0600 "$oc/obenhub.env"
# the sed script comes from a printf builtin through a pipe, so no password is in any argv
sed -i -f <(printf '%s\n' \
  "s#^OBENHUB_GATEWAY_ENDPOINT=.*#OBENHUB_GATEWAY_ENDPOINT=https://gateway:4318#" \
  "s#^OBENHUB_CLUSTER_NAME=.*#OBENHUB_CLUSTER_NAME=free#" \
  "s#^OBENHUB_ORACLE_DB_UNIQUE_NAME=.*#OBENHUB_ORACLE_DB_UNIQUE_NAME=FREE#" \
  "s#^OBENHUB_ORACLE_HOST=.*#OBENHUB_ORACLE_HOST=ora#" \
  "s#^OBENHUB_ORACLE_SERVICE=.*#OBENHUB_ORACLE_SERVICE=FREE#" \
  "s#^OBENHUB_ORACLE_MON_PASSWORD=.*#OBENHUB_ORACLE_MON_PASSWORD=$monpw#" \
  "s#^OBENHUB_ORACLE_DG_PASSWORD=.*#OBENHUB_ORACLE_DG_PASSWORD=$dgpw#" \
  "s#^OBENHUB_ORACLE_ALERT_LOG=.*#OBENHUB_ORACLE_ALERT_LOG=/nonexistent/alert_FREE.log#") "$oc/obenhub.env"
grep -v '^#' "$oc/obenhub.env" | grep -v '^$' | grep -v PASSWORD | sed 's/^/env: /'
# docker --env-file keeps single quotes that a shell would strip (none in this file; same sed as the PostgreSQL pages)
( umask 077; sed -n "s/^\([A-Z_0-9]*\)='\(.*\)'$/\1=\2/p;t;/^[A-Z_0-9]*=/p" "$oc/obenhub.env" >"$tmp/docker.env" )
# no chmod -R a+rX: the container runs as this user (--user), $tmp and $oc are owner-only, and the files keep
# their modes (obenhub.env, docker.env and tls/client.key stay 0600 or 0644 for the certificates)
log "Collector: start $OTELCOL_IMAGE"
docker run -d --name "$colc" --network "$net" --user "$(id -u):$(id -g)" --env-file "$tmp/docker.env" \
  --tmpfs /var/lib/otelcol-contrib:mode=1777 -v "$oc:/etc/otelcol-contrib:ro" "$OTELCOL_IMAGE" \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/oracledb-dg/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/oracledb-backup/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml >/dev/null
docker network connect "$mon" "$colc"
tcol=$(date +%s)

# f. settle, then the error count of the Collector's log and the memory of the Oracle container
settle_wait collector_alive collector_diag
docker logs "$colc" 2>&1 | grep -ci 'error' | sed 's/^/Collector log lines with "error": /' || true
docker logs "$colc" 2>&1 | grep -i 'error' | sed 's/^[0-9TZ:.-]* *//' | cut -c1-200 | sort | uniq -c | sort -rn | head -5 || true
ora_mem_mib=$(docker stats --no-stream --format '{{.MemUsage}}' "$orac" | sed -E 's/^([0-9.]+)([KMG])iB.*/\1 \2/' | awk '{ m = ($2 == "G") ? $1 * 1024 : ($2 == "K") ? $1 / 1024 : $1; printf "%d", m }')
log "Oracle container memory: ${ora_mem_mib} MiB"

assert_backend

# the backup rule's own expression must be empty: the primary has a database backup on record
# (this is the negation of OracleBackupMissing, which the settle does not wait out)
vm="http://127.0.0.1:$p_vm"
# the rule's expression is read from the pack, so it cannot drift from what vmalert evaluates
bm_expr=$(yq -r '.groups[].rules[] | select(.alert == "OracleBackupMissing") | .expr' "$repo/packs/oracledb-backup/rules.yml")
[ -n "$bm_expr" ] || fail "OracleBackupMissing expr not found in packs/oracledb-backup/rules.yml"
bm=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode "query=$bm_expr" | jq -r '.data.result | length')
[ "$bm" = 0 ] || fail "OracleBackupMissing expression returns $bm series: no backup.age of kind database for the primary"
n_primary=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode 'query=count(last_over_time(oracledb.database.primary{service.instance.id="FREE"}[2m]) == 1)' | jq -r '.data.result[0].value[1] // "0"')
[ "$n_primary" = 1 ] || fail "oracledb.database.primary == 1 for FREE: $n_primary series, want 1"
log "backup: OracleBackupMissing expression empty ($bm series), primary series $n_primary"

# what the page says about a database without a standby: the Data Guard signals read as "not applicable", not as a fault
# (value of a series of FREE; instant queries with a bare __name__ matcher returned nothing in debug runs, so the test
# always adds the instance matcher)
vq() { curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode "query=max(last_over_time({__name__=\"$1\",\"service.instance.id\"=\"FREE\"}[2m]))" | jq -r '.data.result[0].value[1] // "none"'; }
for pair in oracledb.dataguard.protection.degraded=0 oracledb.fast_start_failover.enabled=0 oracledb.archive_dest.valid=1 oracledb.archive_dest.gapped=0 oracledb.user.open=1; do
  v=$(vq "${pair%=*}")
  if [ "$v" = "${pair#*=}" ]; then log "series ${pair%=*}: $v"; else fail "series ${pair%=*} is $v, want ${pair#*=} on a primary without standby"; fi
done

# the receiver's own metrics, from the oracledb receiver (30 s): a series of each is the proof that C##OBENHUB_MON works
for m in oracledb.sessions.usage oracledb.tablespace_size.usage; do
  c=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode "query=count(last_over_time({__name__=\"$m\",\"service.instance.id\"=\"FREE\"}[2m]))" | jq -r '.data.result[0].value[1] // "0"')
  if [ "${c:-0}" -ge 1 ]; then log "oracledb receiver: $m has $c series"; else fail "no series of $m (oracledb receiver, C##OBENHUB_MON)"; fi
done

# panels of the Oracle dashboard, with the lib's rule (check-panels.sh) and the empty-by-design list of the header
assert_oracle_panels() {
  local -A legit_empty=(
    ["Redo apply running"]="no standby: the managed recovery process exists on a standby only"
    ["Standby lag"]="no standby: V\$DATAGUARD_STATS has no rows on a primary"
    ["Lag data age"]="no standby: V\$DATAGUARD_STATS has no rows on a primary"
    ["Redo apply and archive gap"]="no standby: apply state and V\$ARCHIVE_GAP are read on a standby only"
    ["Recovery area used, reclaimable counted as free"]="the image sets no db_recovery_file_dest, so V\$RECOVERY_FILE_DEST has no row"
  )
  local panels_out="$tmp/panels.txt" envf="$cdir/.env" line status title
  local empty_titles=() dash="$repo/packs/oracledb-dg/dashboards/oracle-dg.json"
  : >"$panels_out"
  "$repo/scripts/check-panels.sh" "$dash" "$gf" "$envf" >>"$panels_out" 2>&1 || true
  total_panels=$(jq '[.panels[] | if .type == "row" then (.panels // [])[] else . end | select(.type != "row")] | length' "$dash")
  while IFS= read -r line; do
    status=${line%% *}
    title=$(sed -E 's/^[A-Za-z]+ +//;s/ +(ok|FAIL|empty \(allowed\)) [A-Z]:.*$//' <<<"$line")
    case "$status" in
      ok) p_ok=$((p_ok + 1)) ;;
      empty) p_empty=$((p_empty + 1)); empty_titles+=("$title (allowed by check-panels.sh: log or scenario-only panel)") ;;
      FAIL)
        if [ -n "${legit_empty[$title]:-}" ] && ! grep -q 'ERROR\|missing\|unparsable' <<<"$line"; then
          p_legit=$((p_legit + 1)); empty_titles+=("$title (accepted: ${legit_empty[$title]})")
        else
          p_fail=$((p_fail + 1)); fail "panel without data: $title"
        fi ;;
    esac
  done < <(grep -E '^(ok|empty|FAIL) ' "$panels_out")
  cat "$panels_out"
  local accounted=$((p_ok + p_empty + p_legit + p_fail))
  [ "$accounted" -eq "$total_panels" ] || fail "panels accounted for: $accounted of $total_panels (check-panels.sh output incomplete)"
  [ "$p_ok" -gt 0 ] || fail "no panel has data"
  printf 'empty panels:\n'; printf '  %s\n' "${empty_titles[@]}"
  empty_names=$(printf '%s\n' "${empty_titles[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')
}
assert_oracle_panels

EVIDENCE_EXTRA=$(jq -nc --arg banner "$ora_banner" --argjson ready "$ora_ready_s" --argjson mem "$ora_mem_mib" \
  '{oracle: {banner: $banner, ready_seconds: $ready, container_mem_mib: $mem, users: "deploy/oracle/monitoring-user.sql", rman_backup: "online, one"}}')

# the EXIT trap prints the summary line and appends the evidence row
completed=true
exit 0
