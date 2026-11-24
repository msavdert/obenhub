#!/usr/bin/env bash
# CDB26 compatibility check of the oracledb receiver (ADR 0008 decision 3,
# roadmap E4): does the pinned otelcol-contrib scrape CDB26 (26ai, no standby)
# with the receiver settings of files/otelcol-obs.yaml, and which metrics does
# it emit there compared with CDB19. The pack queries on CDB26 are covered by
# `mise run packs:oracle-sql-test`; this is the receiver half. Steps:
#   1. converge C##OBENHUB_MON on CDB26 (same profile, grants and
#      CONTAINER_DATA=ALL as provision.sh, MON_USER only; mon-lib.sh) and check
#      that it logs in and sees every container in V$CON_SYSSTAT;
#   2. run the pinned otelcol-contrib image (the digest of lab/oracle/mon/
#      compose.yaml, which must carry OTELCOL_VERSION of lab/pgha/versions.sh)
#      on this box, one container per database, with only the oracledb
#      receiver: its block is cut out of files/otelcol-obs.yaml, only the
#      endpoint (the ssh address of the VM, the lab DNS name does not resolve
#      here) and the service name change; the exporter is a file; it runs
#      for 3 collection intervals plus the first scrape; CDB26 first, then
#      CDB19 (read-only: the user exists there, provision.sh);
#   3. print per database the Collector's error and warning log lines and the
#      metric names with their series counts, then the difference. Exit 1
#      when CDB26 logged an error or emitted no metric.
# Usage: cdb26-check.sh [--reset-passwords]
# Changes on the database: CDB26 only, profile C##OBENHUB_MON and user
# C##OBENHUB_MON with CREATE SESSION, SELECT on the views of MON_VIEWS and
# CONTAINER_DATA=ALL; an existing user keeps its password unless
# --reset-passwords. Nothing is changed on CDB19 or elsewhere, no restart, no
# parameter. The password comes from lab/oracle/.env and reaches sqlplus on
# stdin and the container as an environment variable (docker -e NAME, no
# value on a command line); it is in no other file and the report masks it.
# Assumes: docker on this box with the pinned image, this box reaches the
# ssh address of the VM on the listener port, CDB26 and CDB19 run on
# CDB_HOST (default PRIMARY_HOST of pair.sh), /etc/oratab lists both SIDs,
# python3 for the report.
# shellcheck disable=SC2029  # remote command lines are built here on purpose
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/../pgha/lab-config.sh"
lab_config "$dir/pair.sh"

reset=0
case "${1:-}" in
  --reset-passwords) reset=1 ;;
  "") ;;
  *) echo "usage: cdb26-check.sh [--reset-passwords]" >&2; exit 2 ;;
esac

# shellcheck source=lab/oracle/scripts/mon-lib.sh
. "$dir/scripts/mon-lib.sh"
mon_env

root="$(cd "$dir/../.." && pwd)"
CDB_HOST=${CDB_HOST:-$PRIMARY_HOST}
NEW_SID=CDB26
REF_SID=$PRIMARY_SID
obs="$dir/files/otelcol-obs.yaml"

image="$(grep -m1 -o 'otel/opentelemetry-collector-contrib:[^ "]*' "$dir/mon/compose.yaml")"
# shellcheck source=/dev/null
version="$(. "$root/lab/pgha/versions.sh" && echo "$OTELCOL_VERSION")"
case "$image" in
  *":$version@sha256:"*) ;;
  *) echo "cdb26-check: $image in mon/compose.yaml is not OTELCOL_VERSION $version" >&2; exit 1 ;;
esac
command -v docker >/dev/null || { echo "cdb26-check: docker not found" >&2; exit 1; }

# the oracledb receiver block of the observer's configuration, as it is
rcv="$(awk '/^  oracledb:$/ {on=1; print; next} on && /^  [^ ]/ {exit} on' "$obs")"
interval="$(printf '%s\n' "$rcv" | sed -n 's/^    collection_interval: \([0-9][0-9]*\)s$/\1/p')"
[ -n "$interval" ] || { echo "cdb26-check: no collection_interval in the oracledb block of $obs" >&2; exit 1; }
for k in endpoint service username password; do
  printf '%s\n' "$rcv" | grep -q "^    $k: " || { echo "cdb26-check: no $k in the oracledb block of $obs" >&2; exit 1; }
done

addr="$(ssh -G "$CDB_HOST" | awk '$1 == "hostname" {print $2}')"
[ -n "$addr" ] || { echo "cdb26-check: cannot resolve the ssh address of $CDB_HOST" >&2; exit 1; }
timeout 5 bash -c "exec 3<>/dev/tcp/$addr/$LISTENER_PORT" 2>/dev/null ||
  { echo "cdb26-check: $addr:$LISTENER_PORT is not reachable from this box" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() {
  docker rm -f obenhub-cdb26-check-new obenhub-cdb26-check-ref >/dev/null 2>&1 || true
  rm -rf "${work:?}"
}
trap cleanup EXIT

# --- CDB26: service, user, grants, login ---------------------------------------
home="$(oh "$CDB_HOST" "$NEW_SID")"
[ -n "$home" ] || { echo "cdb26-check: $NEW_SID not in /etc/oratab on $CDB_HOST" >&2; exit 1; }
svc="$(printf "set head off feedback off pages 0\nselect name from v\$services where name = '%s';\nexit\n" "$NEW_SID" | sysdba "$CDB_HOST" "$NEW_SID" | xargs || true)"
[ "$svc" = "$NEW_SID" ] || { echo "cdb26-check: service $NEW_SID is not in V\$SERVICES of $NEW_SID" >&2; exit 1; }

log "$CDB_HOST" "profile and $MON_USER on $NEW_SID"
mon_sql "$NEW_SID" "$CDB_HOST" 0 "$reset" | sysdba "$CDB_HOST" "$NEW_SID"

out="$(printf 'whenever sqlerror exit failure\nconnect "%s"/"%s"@//localhost:%s/%s\nset head off feedback off pages 0\n%s\nexit\n' \
  "$MON_USER" "$MON_PW" "$LISTENER_PORT" "$NEW_SID" \
  "select 'v\$con_sysstat=' || (select count(distinct con_id) from v\$con_sysstat) || ' v\$containers=' || (select count(*) from v\$containers) from dual;" |
  ssh "${SSH_OPTS[@]}" "$CDB_HOST" "sudo -u oracle env ORACLE_HOME=$home $home/bin/sqlplus -s -L /nolog" 2>&1)" || {
  echo "cdb26-check: login $MON_USER@$NEW_SID failed: $(echo "$out" | grep -m1 ORA- || echo "$out" | head -1); if the user existed with another password, rerun with --reset-passwords" >&2
  exit 1; }
log "$CDB_HOST" "$MON_USER@$NEW_SID -> $(echo "$out" | xargs)"
seen=${out#*v\$con_sysstat=}; seen=${seen%% *}; all=${out##*v\$containers=}; all=${all%%[!0-9]*}
[ "$seen" = "$all" ] || { echo "cdb26-check: $MON_USER sees $seen of $all containers in v\$con_sysstat (CONTAINER_DATA)" >&2; exit 1; }

# --- the receiver, one container per database -----------------------------------
# collect <label> <service>: oracledb receiver of the observer's block against
# <service>, 3 intervals after the first scrape, output under $work/<label>
collect() {
  local label=$1 service=$2 d="$work/$1"
  mkdir -p "$d/out"
  {
    echo "receivers:"
    printf '%s\n' "$rcv" | sed -e "s|^    endpoint: .*|    endpoint: $addr:$LISTENER_PORT|" -e "s|^    service: .*|    service: $service|"
    cat <<'YAML'
exporters:
  file:
    path: /out/metrics.jsonl
service:
  telemetry:
    logs:
      encoding: json
    metrics:
      level: none
  pipelines:
    metrics:
      receivers: [oracledb]
      exporters: [file]
YAML
  } >"$d/config.yaml"
  log "$(hostname -s)" "$label: oracledb receiver -> $service ($addr:$LISTENER_PORT), $((3 * interval + 5)) s"
  # the user owns the output; the password is handed over by name only
  ORA_MON_PASSWORD="$MON_PW" docker run -d --name "obenhub-cdb26-check-$label" \
    --user "$(id -u):$(id -g)" -e ORA_MON_PASSWORD \
    -v "$d/config.yaml:/etc/otelcol/config.yaml:ro" -v "$d/out:/out" \
    "$image" --config=/etc/otelcol/config.yaml >/dev/null
  sleep $((3 * interval + 5))
  docker stop -t 10 "obenhub-cdb26-check-$label" >/dev/null
  docker logs "obenhub-cdb26-check-$label" >"$d/collector.log" 2>&1
  docker rm "obenhub-cdb26-check-$label" >/dev/null
}
# One login of the reference database before its receiver starts: with a wrong
# password the receiver would retry every interval and could lock the account
# the lab Collector uses (FAILED_LOGIN_ATTEMPTS of the profile).
ref_home="$(oh "$CDB_HOST" "$REF_SID")"
[ -n "$ref_home" ] || { echo "cdb26-check: $REF_SID not in /etc/oratab on $CDB_HOST" >&2; exit 1; }
out="$(printf 'whenever sqlerror exit failure\nconnect "%s"/"%s"@//localhost:%s/%s\nset head off feedback off pages 0\nselect 1 from dual;\nexit\n' \
  "$MON_USER" "$MON_PW" "$LISTENER_PORT" "$REF_SID" |
  ssh "${SSH_OPTS[@]}" "$CDB_HOST" "sudo -u oracle env ORACLE_HOME=$ref_home $ref_home/bin/sqlplus -s -L /nolog" 2>&1)" || {
  echo "cdb26-check: login $MON_USER@$REF_SID failed: $(echo "$out" | grep -m1 ORA- || echo "$out" | head -1); not starting the reference receiver (provision.sh --reset-passwords converges the password)" >&2
  exit 1; }

collect new "$NEW_SID"
collect ref "$REF_SID"

# --- report -----------------------------------------------------------------------
echo
echo "otelcol-contrib $version ($image)"
echo "receiver block: $obs (oracledb), collection_interval ${interval}s, user $MON_USER"
MON_PW="$MON_PW" python3 -I - "$NEW_SID" "$work/new" "$REF_SID" "$work/ref" <<'PY'
import json, os, re, sys

pw = os.environ["MON_PW"]


def scrub(s):
    return s.replace(pw, "***")


def logs(path):
    """error and warn lines of the Collector's JSON log: {message: count}"""
    out, total = {}, 0
    for line in open(path, errors="replace"):
        total += 1
        try:
            r = json.loads(line)
        except ValueError:
            r = {"level": "raw", "msg": line.strip()}
        if r.get("level") in ("error", "warn", "raw"):
            msg = scrub(r.get("level", "") + " " + r.get("msg", "") + " " + str(r.get("error", ""))).strip()
            msg = re.sub(r"\s+", " ", msg)
            out[msg] = out.get(msg, 0) + 1
    return out, total


def attrs(lst):
    return tuple(sorted((a["key"], next(iter(a["value"].values()))) for a in lst or []))


def metrics(path):
    """({name: set of series}, scrapes = lines of the file exporter, resource attributes)"""
    names, res, scrapes = {}, set(), 0
    p = os.path.join(path, "out", "metrics.jsonl")
    if not os.path.exists(p):
        return names, 0, res
    for line in open(p):
        scrapes += 1
        for rm in json.loads(line).get("resourceMetrics", []):
            ra = attrs(rm.get("resource", {}).get("attributes"))
            res.add(ra)
            for sm in rm.get("scopeMetrics", []):
                for m in sm.get("metrics", []):
                    kind = next(k for k in ("gauge", "sum", "histogram", "summary") if k in m)
                    for dp in m[kind].get("dataPoints", []):
                        names.setdefault(m["name"], set()).add((ra, attrs(dp.get("attributes"))))
    return names, scrapes, res


data = {}
for sid, path in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    msgs, nlog = logs(os.path.join(path, "collector.log"))
    names, stamps, res = metrics(path)
    data[sid] = (msgs, names)
    print(f"\n== {sid}: {len(names)} metric names, {sum(len(v) for v in names.values())} series, "
          f"{stamps} scrapes with data, {nlog} log lines")
    for r in sorted(res):
        print("   resource:", dict(r))
    if msgs:
        print(f"   error/warn log lines ({sum(msgs.values())}):")
        for m, n in sorted(msgs.items()):
            print(f"     {n} x {m[:400]}")
    else:
        print("   error/warn log lines: none")

(a, (ma, na)), (b, (mb, nb)) = data.items()
print(f"\n== difference, {a} against {b}")
only_a, only_b = sorted(set(na) - set(nb)), sorted(set(nb) - set(na))
print(f"only on {a} ({len(only_a)}):", *[f"\n   {n} ({len(na[n])} series)" for n in only_a] or ["none"])
print(f"only on {b} ({len(only_b)}):", *[f"\n   {n} ({len(nb[n])} series)" for n in only_b] or ["none"])
diff = [n for n in sorted(set(na) & set(nb)) if len(na[n]) != len(nb[n])]
print(f"in both with another series count ({len(diff)}):", *[f"\n   {n}: {a} {len(na[n])}, {b} {len(nb[n])}" for n in diff] or ["none"])
for n in diff:
    sa, sb = {s[1] for s in na[n]}, {s[1] for s in nb[n]}
    for x in sorted(sa - sb):
        print(f"   {n} only on {a}: {dict(x)}")
    for x in sorted(sb - sa):
        print(f"   {n} only on {b}: {dict(x)}")
print(f"in both with the same series count: {len(set(na) & set(nb)) - len(diff)}")
print(f"\nmetric names on {a}:")
for n in sorted(na):
    print(f"   {n} {len(na[n])}")
if any(m.startswith(("error", "raw")) for m in ma) or not na:
    sys.exit(1)
PY
