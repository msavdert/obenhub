#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install test of docs/guides/monitor/vm.md (roadmap G1b): the backend of
# deploy/compose on this machine, and on a second machine (an ssh target, Debian
# or Ubuntu with systemd and sudo) a fresh PostgreSQL cluster made by Debian's
# postgresql-common with its default configuration, and the upstream
# otelcol-contrib .deb of the gateway's version running under the package's own
# systemd unit. It then runs the assertions of install-test.sh (lib.sh): the
# heartbeat, nothing but Watchdog firing, the dead-man cadence, the panels of
# the PostgreSQL and host dashboards. One JSON line per run goes to
# deploy/results/runs.jsonl ("test": "vm-test"). Needs docker, jq, curl,
# openssl, ssh on this machine; takes about 20 minutes. Not part of
# `mise run check`.
#   mise run deploy:vm-test [-- --force]
# Environment: VM_TEST_TARGET (ssh host, default pg-lab), VM_TEST_ADDR (this
# machine's address as the target reaches it, goes into the gateway certificate;
# default 10.0.0.11), VM_TEST_PORT_BASE (default 61100; six ports from there are
# bound, the gateway's on VM_TEST_ADDR when that is an IPv4 address, the others
# on 127.0.0.1), VM_TEST_EVIDENCE=0 to skip the runs.jsonl line, VM_TEST_SETTLE=
# <seconds> to shorten the settle while debugging (no evidence line then).
#
# Fail closed: every refusal check runs, read-only, before the script changes
# anything on the target, and a refusal writes no evidence line (exit 2). It
# refuses, whatever the flags, when the target has a PostgreSQL cluster
# 18/vmtest or a /etc/postgresql/18/vmtest, a package otelcol-contrib, a listener
# on port 5433, /tmp/obenhub-vm-test, or any <path>.vm-test-aside for the three
# paths below (a stale aside of an earlier run is reported, never acted on). It
# also refuses when /etc/otelcol-contrib, /var/lib/otelcol-contrib or
# /etc/systemd/system/otelcol-contrib.service.d exists, unless --force: then it
# moves that path to <path>.vm-test-aside and puts it back on exit (mv -T; if the
# path exists again at that point the aside stays where it is and the run fails).
# A package install, a cluster and a stale aside are never forced. On exit the
# test undoes only what it did: it purges the package when one is installed,
# removes the files and the user and group it created, drops its own cluster,
# restores what it moved, takes the compose project down, and a teardown failure
# fails the run and the evidence line.
# shellcheck disable=SC2329  # functions are called from the EXIT trap and settle_wait
set -euo pipefail

# shellcheck source=deploy/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_NAME="vm-test"
force=false
for a in "$@"; do
  case "$a" in
    --force) force=true ;;
    *) echo "usage: vm-test.sh [--force]   (see the header for the environment)" >&2; exit 2 ;;
  esac
done

project=obenhub-vm-test
target="${VM_TEST_TARGET:-pg-lab}"
addr="${VM_TEST_ADDR:-10.0.0.11}"
cluster=vmtest   # no dash: Debian's postgresql@.service uses %I, which breaks on one
pgver=18
pgport=5433
work=/tmp/obenhub-vm-test   # literal on purpose: rm of $work always removes this one path
aside_suffix=.vm-test-aside
confdir=/etc/postgresql/18/vmtest   # pgver and cluster, literal because rm and rmdir take literal paths
[ "$confdir" = "/etc/postgresql/$pgver/$cluster" ] || { echo "vm-test: confdir does not match pgver and cluster" >&2; exit 2; }
asides=(/etc/otelcol-contrib /var/lib/otelcol-contrib /etc/systemd/system/otelcol-contrib.service.d)

# the host Collector is the version of the gateway image (deploy/compose/compose.yaml)
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' "$repo/deploy/compose/compose.yaml")"
[ -n "$OTELCOL_IMAGE" ] || { echo "vm-test: gateway image not found in compose.yaml" >&2; exit 2; }
otel_tag="${OTELCOL_IMAGE#*:}"; otel_version="${otel_tag%%@*}"
rel_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$otel_version"

base="${VM_TEST_PORT_BASE:-61100}"
p_grafana=$base p_vm=$((base + 1)) p_vl=$((base + 2)) p_vmalert=$((base + 3)) p_am=$((base + 4)) p_gw=$((base + 5))
lib_check_ports "set VM_TEST_PORT_BASE"
gateway_bind=0.0.0.0
if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then gateway_bind=$addr; fi

# the file the test adds to the cluster's conf.d, and the directories pg_dropcluster leaves because of it
remove_conf_leftover() {
  t 'sudo rm -f /etc/postgresql/18/vmtest/conf.d/obenhub.conf'
  t 'sudo test ! -e /etc/postgresql/18/vmtest/conf.d || sudo rmdir /etc/postgresql/18/vmtest/conf.d'
  t 'sudo test ! -e /etc/postgresql/18/vmtest || sudo rmdir /etc/postgresql/18/vmtest'
}

# t runs a command on the target (the argument is one shell command line there);
# ti does the same and passes its standard input on
t() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$target" "$@"; }
ti() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "$@"; }
cluster_listed() { t "pg_lsclusters -h | awk '\$1 == \"$pgver\" && \$2 == \"$cluster\"' | grep -q ."; }
exists() { t "sudo test -e $1 || sudo test -L $1"; }
refuse() { echo "vm-test: $*" >&2; exit 2; }

# ---- preflight: read-only, and every refusal before the first change on the target
# (a refusal writes no evidence line)
t true || refuse "cannot ssh to $target"
t 'sudo -n true' || refuse "$target needs passwordless sudo"
t 'command -v apt-get dpkg systemctl curl sha256sum pg_createcluster pg_dropcluster >/dev/null' \
  || refuse "$target lacks one of apt-get, dpkg, systemctl, curl, sha256sum, pg_createcluster, pg_dropcluster (Debian or Ubuntu with postgresql-common and postgresql-$pgver)"
t "test -x /usr/lib/postgresql/$pgver/bin/postgres" || refuse "$target has no postgresql-$pgver"
t "ls /usr/share/postgresql/$pgver/extension/pg_stat_statements.control >/dev/null" || refuse "$target has no pg_stat_statements (postgresql-$pgver contrib files)"
if t 'dpkg -s otelcol-contrib >/dev/null 2>&1'; then
  refuse "$target has the package otelcol-contrib installed; the test would purge it. Remove it yourself first (never forced)."
fi
if t "ss -ltn | awk '{print \$4}' | grep -q ':$pgport\$'"; then
  refuse "port $pgport on $target is in use (never forced)"
fi
if cluster_listed; then
  refuse "$target already has cluster $pgver/$cluster; remove it yourself first (never forced, never touched)"
fi
if exists "$confdir"; then
  refuse "$confdir exists on $target (what is left of a cluster $pgver/$cluster); remove it yourself first (never forced, never touched)"
fi
exists "$work" && refuse "$work exists on $target; remove it by hand (never forced)"
declare -a to_move=()
for p in "${asides[@]}"; do
  if exists "$p$aside_suffix"; then
    refuse "$p$aside_suffix exists on $target (an aside of an earlier run?); inspect it and remove or restore it yourself (never forced, never touched)"
  fi
done
for p in "${asides[@]}"; do
  if exists "$p"; then
    $force || refuse "$target has $p that is not from this test; pass --force to move it aside (to $p$aside_suffix) and put it back on exit"
    to_move+=("$p")
  fi
done
user_existed=false group_existed=false
if t 'getent passwd otelcol-contrib >/dev/null'; then user_existed=true; fi
if t 'getent group otelcol-contrib >/dev/null'; then group_existed=true; fi

lib_init
EVIDENCE_EXTRA='{"target": {"kind": "second machine over ssh", "collector": "otelcol-contrib .deb, package unit otelcol-contrib.service"}}'

# What the test did on the target. a_* are set before the command that may
# create something (teardown then checks that it exists); `moved` gets a path
# only after its mv succeeded.
a_work=false a_cluster=false a_pkg=false
declare -a moved=()
teardown() {
  set +e
  local p
  if $a_pkg; then
    t 'sudo systemctl stop otelcol-contrib' >/dev/null 2>&1
    if t 'dpkg-query -W otelcol-contrib >/dev/null 2>&1'; then
      t 'sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y otelcol-contrib' >/dev/null 2>&1 || fail "teardown: apt-get purge otelcol-contrib"
    fi
    # an install was attempted, so what is at these paths is ours: the preflight
    # found them absent or moved them aside (a failed apt-get may leave files)
    t 'sudo rm -rf /etc/otelcol-contrib /var/lib/otelcol-contrib /etc/systemd/system/otelcol-contrib.service.d' || fail "teardown: removing the test's files"
    t 'sudo systemctl daemon-reload; sudo systemctl reset-failed otelcol-contrib' >/dev/null 2>&1
    # the package creates the user in its preinst and never removes it
    if ! $user_existed && t 'getent passwd otelcol-contrib >/dev/null'; then
      t 'sudo userdel otelcol-contrib' >/dev/null 2>&1 || fail "teardown: userdel otelcol-contrib"
    fi
    if ! $group_existed && t 'getent group otelcol-contrib >/dev/null'; then
      t 'sudo groupdel otelcol-contrib' >/dev/null 2>&1 || fail "teardown: groupdel otelcol-contrib"
    fi
  fi
  if $a_cluster; then
    # the preflight found no such cluster, so a listed one is ours
    if cluster_listed; then
      t "sudo pg_dropcluster --stop $pgver $cluster" >/dev/null 2>&1 || fail "teardown: pg_dropcluster $pgver $cluster"
    fi
    remove_conf_leftover || fail "teardown: removing $confdir"
  fi
  if $a_work; then t "sudo rm -rf $work" || fail "teardown: removing $work"; fi
  for p in "${moved[@]}"; do
    if exists "$p"; then
      fail "teardown: $p exists, so $p$aside_suffix is not moved back over it; the original stays in $p$aside_suffix"
    else
      t "sudo mv -T $p$aside_suffix $p" || fail "teardown: restoring $p from $p$aside_suffix"
    fi
  done
  if [ "${#moved[@]}" -gt 0 ]; then t 'sudo systemctl daemon-reload' >/dev/null 2>&1; fi
  backend_down
  tmp_remove
}
collector_alive() { t 'systemctl is-active --quiet otelcol-contrib'; }
collector_diag() { t 'sudo journalctl -u otelcol-contrib -n 30 --no-pager'; }

for p in "${to_move[@]}"; do
  log "target: --force, moving $p to $p$aside_suffix"
  t "sudo mv -T $p $p$aside_suffix"
  moved+=("$p")
done
a_work=true
t "install -d -m 0755 $work $work/tls"

# a. backend on this machine, gateway reachable from the target, certificate for its address
backend_up "$addr"
gwurl="https://$addr:$p_gw"
t "timeout 5 bash -c '</dev/tcp/$addr/$p_gw'" || fail "the gateway $addr:$p_gw is not reachable from $target"

# b. a fresh cluster, Debian's defaults: postgresql-common's pg_createcluster
a_cluster=true
log "target: pg_createcluster $pgver $cluster --port $pgport"
t "sudo pg_createcluster $pgver $cluster --port $pgport --start" >"$tmp/createcluster.log" 2>&1 || { cat "$tmp/createcluster.log" >&2; fail "pg_createcluster"; }
log "pg_createcluster ran: $(grep -m1 'initdb ' "$tmp/createcluster.log" || true)"
# what the guide's table says a default server already has: a host rule for
# 127.0.0.1 and listen_addresses = localhost (both still the defaults)
hba=$(t "sudo grep -E '^host +all +all +127\\.0\\.0\\.1/32 ' /etc/postgresql/$pgver/$cluster/pg_hba.conf" || true)
log "pg_hba.conf: ${hba:-no 127.0.0.1 host rule}"
[ -n "$hba" ] || fail "the default pg_hba.conf has no host rule for 127.0.0.1/32"
lsrc=$(t "sudo -u postgres psql -p $pgport -Atc \"SELECT setting || ' (' || source || ')' FROM pg_settings WHERE name = 'listen_addresses'\"")
log "listen_addresses: $lsrc"
[ "$lsrc" = "localhost (default)" ] || fail "listen_addresses is '$lsrc', not the default localhost"
pgv=$(t "sudo -u postgres psql -p $pgport -Atc 'SELECT version()'")
log "server: $pgv"

# the guide's optional row: pg_stat_statements needs the library preloaded (restart) and the extension
echo "shared_preload_libraries = 'pg_stat_statements'" | ti "sudo tee /etc/postgresql/$pgver/$cluster/conf.d/obenhub.conf >/dev/null"
t "sudo pg_ctlcluster $pgver $cluster restart"
t "sudo -u postgres psql -p $pgport -d postgres -v ON_ERROR_STOP=1 -qc 'CREATE EXTENSION pg_stat_statements'" || fail "CREATE EXTENSION pg_stat_statements"

# the monitoring role of step 2 of the guide; the password reaches psql through stdin and the environment, not argv
monpw="$(openssl rand -hex 12)"
ti "tar -C $work -xf -" < <(tar -C "$repo" -cf - packs/otelcol-base.yaml packs/collector packs/host packs/postgresql deploy/collector)
t "sudo chmod -R a+rX $work"
printf '%s\n' "$monpw" | ti "read -r OTEL_MONITOR_PASSWORD; export OTEL_MONITOR_PASSWORD; sudo --preserve-env=OTEL_MONITOR_PASSWORD -u postgres psql -p $pgport -v ON_ERROR_STOP=1 -q -c '\\getenv mon_pw OTEL_MONITOR_PASSWORD' -f $work/packs/postgresql/monitoring-role.sql >/dev/null" \
  || fail "monitoring-role.sql"
# the same login the Collector will use, over TCP on 127.0.0.1 (pg_hba: scram-sha-256)
printf '%s\n' "$monpw" | ti "read -r PGPASSWORD; export PGPASSWORD; psql -h 127.0.0.1 -p $pgport -U otel_monitor -d postgres -Atc 'SELECT current_user'" | grep -qx otel_monitor \
  || fail "otel_monitor cannot log in over 127.0.0.1:$pgport"

# c. the upstream package, checked against the release's checksum, installed with apt
deb="otelcol-contrib_${otel_version}_linux_$(t 'dpkg --print-architecture').deb"
log "target: download $deb ($rel_url)"
a_pkg=true
t "cd $work && curl -fsSLO $rel_url/$deb && curl -fsSLO $rel_url/$deb.sha256" || fail "downloading $deb and its checksum"
sum=$(t "cd $work && awk '{print \$1}' $deb.sha256")
log "release checksum of $deb: $sum"
t "cd $work && echo '$sum  $deb' | sha256sum -c -" || fail "sha256 of $deb does not match the release's"
t "cd $work && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ./$deb" >"$tmp/apt.log" 2>&1 || { tail -20 "$tmp/apt.log" >&2; fail "apt-get install $deb"; }
# shellcheck disable=SC2016  # the ${...} is dpkg-query's format, expanded on the target
log "target: installed $(t 'dpkg-query -W -f "\${Package} \${Version}" otelcol-contrib')"

# d. files, environment, options, drop-in, start (the steps of vm.md)
ti "sudo bash -s" <<SH
set -euo pipefail
cd $work
install -d /etc/otelcol-contrib/packs /etc/otelcol-contrib/tls
cp packs/otelcol-base.yaml /etc/otelcol-contrib/packs/
for p in collector host postgresql; do cp -r "packs/\$p" /etc/otelcol-contrib/packs/; done
cp deploy/collector/otelcol-tls.yaml /etc/otelcol-contrib/
cp deploy/collector/obenhub.env.example /etc/otelcol-contrib/obenhub.env
chmod 0600 /etc/otelcol-contrib/obenhub.env
SH
# the TLS files: ca.crt, client.crt, client.key, never ca.key
ti "tar -C $work/tls -xf -" < <(tar -C "$cdir/tls" -cf - ca.crt client.crt client.key)
ti "sudo bash -s" <<SH
set -euo pipefail
cp $work/tls/ca.crt $work/tls/client.crt $work/tls/client.key /etc/otelcol-contrib/tls/
# the service user reads the key through its group; nobody else can
chgrp -R otelcol-contrib /etc/otelcol-contrib/tls
chmod 0750 /etc/otelcol-contrib/tls
chmod 0644 /etc/otelcol-contrib/tls/ca.crt /etc/otelcol-contrib/tls/client.crt
chmod 0640 /etc/otelcol-contrib/tls/client.key
SH
# the five values of the guide's table, set by a sed script that travels on stdin
ti 'sudo sed -i -f /dev/stdin /etc/otelcol-contrib/obenhub.env' <<SED
s#^OBENHUB_GATEWAY_ENDPOINT=.*#OBENHUB_GATEWAY_ENDPOINT=$gwurl#
s#^OBENHUB_PG_HOST=.*#OBENHUB_PG_HOST=127.0.0.1#
s#^OBENHUB_PG_PORT=.*#OBENHUB_PG_PORT=$pgport#
s#^OBENHUB_PG_PASSWORD=.*#OBENHUB_PG_PASSWORD=$monpw#
s#^OBENHUB_PG_LOG_GLOB=.*#OBENHUB_PG_LOG_GLOB=/nonexistent/postgresql-*.json#
SED
ti "sudo bash -s" <<'SH'
set -euo pipefail
# the package's unit reads OTELCOL_OPTIONS from its environment file
sed -i 's#^OTELCOL_OPTIONS=.*#OTELCOL_OPTIONS="--config=/etc/otelcol-contrib/packs/otelcol-base.yaml --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml --config=/etc/otelcol-contrib/packs/host/otelcol.yaml --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml --config=/etc/otelcol-contrib/otelcol-tls.yaml"#' /etc/otelcol-contrib/otelcol-contrib.conf
# a drop-in, not a unit of our own: the obenhub variables, the state directory
# of OBENHUB_STORAGE_DIR, and read access to the journal for the journald receivers
install -d /etc/systemd/system/otelcol-contrib.service.d
cat >/etc/systemd/system/otelcol-contrib.service.d/obenhub.conf <<'UNIT'
[Service]
EnvironmentFile=/etc/otelcol-contrib/obenhub.env
StateDirectory=otelcol-contrib
SupplementaryGroups=systemd-journal
UNIT
systemctl daemon-reload
SH
log "target: systemctl restart otelcol-contrib"
t 'sudo systemctl restart otelcol-contrib' || fail "systemctl restart otelcol-contrib"
tcol=$(date +%s)
inv=$(t 'systemctl show otelcol-contrib -p InvocationID --value')   # this start only: the journal keeps earlier runs
# shellcheck disable=SC2016  # expanded on the target
t 'systemctl cat otelcol-contrib; echo "# $(grep -c . /etc/otelcol-contrib/otelcol-contrib.conf) lines:"; cat /etc/otelcol-contrib/otelcol-contrib.conf' || true

# shellcheck disable=SC2016  # expanded on the target
osname=$(t '. /etc/os-release; echo "$PRETTY_NAME"')
EVIDENCE_EXTRA=$(jq -nc --arg os "$osname" --arg arch "$(t 'dpkg --print-architecture')" --arg v "$otel_version" --arg sum "$sum" --arg pg "$pgv" \
  --arg cl "$pgver/$cluster" --argjson port "$pgport" --arg hba "$hba" \
  '{target: {kind: "second machine over ssh", os: $os, arch: $arch,
     collector: {install: "upstream .deb with the package unit otelcol-contrib.service", version: $v, deb_sha256: $sum},
     postgresql: {server: $pg, cluster: $cl, port: $port, created_by: "pg_createcluster (postgresql-common defaults)", pg_stat_statements: true, pg_hba_rule: $hba},
     journald_receivers: "loaded, read through SupplementaryGroups=systemd-journal"}}')

# e. settle and assert, as install-test does
settle_wait collector_alive collector_diag
nrestarts=$(t 'systemctl show otelcol-contrib -p NRestarts --value')
log "otelcol-contrib NRestarts=$nrestarts, state $(t 'systemctl is-active otelcol-contrib')"
[ "$nrestarts" = 0 ] || fail "systemd restarted otelcol-contrib $nrestarts times"
t "sudo journalctl _SYSTEMD_INVOCATION_ID=$inv --no-pager" >"$tmp/collector.log" 2>&1 || true
# printed and recorded in the evidence line, not asserted
nerr=$(grep -ci 'error' "$tmp/collector.log" || true)
echo "Collector log lines with \"error\" since this start: ${nerr:-0}"
EVIDENCE_EXTRA=$(jq -c --argjson n "${nerr:-0}" '.target.collector_log_error_lines = $n' <<<"$EVIDENCE_EXTRA")
grep -i 'error' "$tmp/collector.log" | cut -c1-300 | sort | uniq -c | sort -rn | head -10 || true

assert_backend

# journald: the host pack's default unit list holds otelcol-contrib, so the
# journal records of the Collector's own unit must be in VictoriaLogs (the query
# form of lab/oracle/README.md, "service.name:host ... journald._SYSTEMD_UNIT").
# The Collector reads the journal as the service user with the group
# systemd-journal from the drop-in.
jn=$(curl -fsS --max-time 20 "$vl/select/logsql/query" --data-urlencode 'query=service.name:host service.instance.id:host-1 journald._SYSTEMD_UNIT:otelcol-contrib.service _time:30m | stats count() c' | jq -r '.c // "0"')
log "journal records of otelcol-contrib.service in VictoriaLogs: $jn"
[ "${jn:-0}" -gt 0 ] || fail "no journald record of otelcol-contrib.service from host-1 in VictoriaLogs"
EVIDENCE_EXTRA=$(jq -c --argjson n "${jn:-0}" '.target.journald_records_of_collector_unit = $n' <<<"$EVIDENCE_EXTRA")

assert_panels

# the EXIT trap prints the summary line, appends the evidence row and tears down
completed=true
exit 0
