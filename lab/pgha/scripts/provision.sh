#!/usr/bin/env bash
# Provision the pgha VMs from this box over ssh: etcd 3.6 (TLS), PostgreSQL
# 18 and Patroni 4 (PGDG packages), and the per-node otelcol-contrib that
# pushes to the gateway of lab/pgha/mon, plus the fault-scenario support
# (nftables, client load unit).
# Usage: provision.sh [node...]   (default: all of lab/pgha/nodes.sh)
# Needs lab/pgha/.env (gen-env.sh, run here if missing) and lab/pgha/pki
# (pki.sh, run every time; it only adds missing files). Idempotent: files are
# replaced only when their content, mode or owner differ, packages and
# binaries only when the pinned version is not installed, and a service is
# restarted/reloaded only when its own config changed. A rerun on a healthy cluster therefore touches nothing.
# Fail closed: all three templates are rendered for every node before anything is
# written; put refuses empty or truncated input. Converge: a file that needs an
# etcd restart or a Patroni reload leaves a marker on the node (MARK_DIR) that
# is removed only after the action succeeded, so an interrupted run is finished
# by the next one.
# Assumes: ssh aliases equal the node names, user with passwordless sudo,
# Debian 13 amd64.
# shellcheck disable=SC2016,SC2029  # remote scripts are single-quoted on purpose
set -euo pipefail
# a failure inside $(...) (render) must stop the script too
shopt -s inherit_errexit

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/versions.sh"
# shellcheck source=/dev/null
. "$dir/nodes.sh"
[ -s "$dir/.env" ] || "$dir/scripts/gen-env.sh"
# pki.sh keeps existing files and adds missing ones (for example the Collector
# certificates of a checkout provisioned before they existed)
"$dir/scripts/pki.sh"
# the file holds only KEY=hex lines (gen-env.sh)
set -a
# shellcheck source=/dev/null
. "$dir/.env"
set +a
PGDG_KEY_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8
pki="$dir/pki"
files="$dir/files"

want="$*"
if [ -z "$want" ]; then for e in $NODES; do want="$want${want:+ }${e%%=*}"; done; fi
ip_of() { local e; for e in $NODES; do if [ "${e%%=*}" = "$1" ]; then echo "${e#*=}"; fi; done; }

ETCD_HOSTS="" ETCD_CLUSTER="" HBA_MEMBERS=""
for e in $NODES; do
  ETCD_HOSTS="$ETCD_HOSTS${ETCD_HOSTS:+, }'${e#*=}:2379'"
  ETCD_CLUSTER="$ETCD_CLUSTER${ETCD_CLUSTER:+,}${e%%=*}=https://${e#*=}:2380"
  HBA_MEMBERS="$HBA_MEMBERS${HBA_MEMBERS:+
}        - hostssl all postgres ${e#*=}/32 scram-sha-256"
done

MARK_DIR=/var/lib/obenhub-pgha
ETCD_MARK=$MARK_DIR/etcd.restart-pending
PATRONI_MARK=$MARK_DIR/patroni.reload-pending
OTEL_MARK=$MARK_DIR/otelcol.restart-pending
declare -A ETCD_CHANGED PATRONI_CHANGED ETCD_UNIT PATRONI_CONF OTEL_CONF
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
# rn <node> <command...>: run a command as root on the node
# ssh joins its arguments into one remote command line, so quote each one
rn() { local n="$1"; shift; ssh "${SSH_OPTS[@]}" "$n" "sudo $(printf '%q ' "$@")"; }
log() { echo "[$1] $2"; }

# render <template> <node>: fill @NAME@ placeholders (bash expansion, so no
# secret reaches a command line)
render() {
  local c n="$2" ip
  ip="$(ip_of "$n")" || return 1
  [ -n "$ip" ] || { echo "render: no IP for node $n" >&2; return 1; }
  c="$(cat "$1")" || return 1
  [ -n "$c" ] || { echo "render: empty template $1" >&2; return 1; }
  c="${c//@NODE@/$n}"
  c="${c//@IP@/$ip}"
  c="${c//@SUBNET@/$SUBNET}"
  c="${c//@PG_MAJOR@/$PG_MAJOR}"
  c="${c//@OTELCOL_VERSION@/$OTELCOL_VERSION}"
  c="${c//@GATEWAY_IP@/$GATEWAY_IP}"
  c="${c//@GATEWAY_PORT@/$GATEWAY_PORT}"
  c="${c//@ETCD_HOSTS@/$ETCD_HOSTS}"
  c="${c//@ETCD_CLUSTER@/$ETCD_CLUSTER}"
  c="${c//@HBA_MEMBERS@/$HBA_MEMBERS}"
  c="${c//@PATRONI_API_PASSWORD@/$PATRONI_API_PASSWORD}"
  c="${c//@REPLICATOR_PASSWORD@/$REPLICATOR_PASSWORD}"
  c="${c//@POSTGRES_PASSWORD@/$POSTGRES_PASSWORD}"
  printf '%s\n' "$c"
}

# put <node> <dest> <mode e.g. 600> <owner:group> [marker] < content
# The temp file is created next to the destination (same filesystem), so the
# final mv is an atomic rename. The content is read whole first: empty input
# is refused, and the remote side checks the byte count, so a truncated
# transfer is never installed. The remote temp file is removed on any exit.
# With a marker path, the marker is created on the node before the file is
# replaced (the action that file needs is then pending until it is removed).
# Never call put at the end of a pipeline: it would run in a subshell and the
# CHANGED update would be lost.
# Sets CHANGED=1 when the file was created or differed.
CHANGED=0
put() {
  local out content LC_ALL=C
  IFS= read -r -d '' content || true
  if [ -z "${content//[[:space:]]/}" ]; then echo "[$1] refusing to write empty $2" >&2; return 1; fi
  out="$(printf '%s' "$content" | rn "$1" sh -c '
    t=$(mktemp "$1.XXXXXX") || exit 1
    trap "rm -f \"$t\"" EXIT HUP INT TERM
    cat >"$t" && chown "$3" "$t" && chmod "$2" "$t" || exit 1
    [ "$(wc -c <"$t")" = "$5" ] || { echo "short write to $1" >&2; exit 1; }
    if [ -e "$1" ] && cmp -s "$t" "$1" && [ "$(stat -c %a:%U:%G "$1")" = "$2:$3" ]; then
      echo same
    else
      if [ -n "$4" ]; then : >"$4" || exit 1; fi
      mv "$t" "$1" || exit 1; echo changed
    fi' sh "$2" "$3" "$4" "${5:-}" "${#content}")"
  if [ "$out" = changed ]; then CHANGED=1; log "$1" "updated $2"; fi
}
# putf <node> <dest> <mode> <owner> <local file> [marker]
putf() { put "$1" "$2" "$3" "$4" "${6:-}" <"$5"; }

phase_base() {
  local n="$1" ip have clusters wd_group
  ip="$(ip_of "$n")"
  log "$n" "base"
  # timezone UTC
  if [ "$(rn "$n" timedatectl show -p Timezone --value)" != UTC ]; then
    rn "$n" timedatectl set-timezone UTC
    log "$n" "timezone set to UTC"
  fi

  # PGDG repo, signed-by keyring. The key is downloaded from postgresql.org
  # to a temp file, its primary fingerprint is compared with the pinned
  # PGDG_KEY_FINGERPRINT and only then moved to the path postgresql-common also uses.
  # postgresql-common may later replace that file with its own copy of the
  # same key; the check below accepts any file with the pinned fingerprint.
  # Fingerprint source: https://www.postgresql.org/download/linux/debian/
  # ("gpg --show-key" output for ACCC4CF8.asc), read 2026-11-09, and equal to
  # what gpg --show-keys printed for the downloaded file the same day.
  # Assumption: the armored key can be used directly as signed-by on trixie
  # (apt accepts .asc keyrings); this is the layout PGDG's own script uses.
  rn "$n" sh -euc '
    k=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    keyfp() { gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: "/^pub/{p++} /^fpr/&&!f{f=\$10} END{if(p==1)print f}"; }
    [ "$(keyfp "$k")" = "$1" ] && exit 0
    command -v gpg >/dev/null || DEBIAN_FRONTEND=noninteractive sh -c "apt-get update -qq && apt-get install -y -qq gpg"
    d=$(mktemp -d); trap "rm -rf $d" EXIT
    curl -fsSL -o "$d/key.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc
    [ "$(keyfp "$d/key.asc")" = "$1" ] || { echo "PGDG key fingerprint mismatch" >&2; exit 1; }
    mkdir -p "$(dirname "$k")"
    install -m 0644 "$d/key.asc" "$k.new" && mv "$k.new" "$k"' sh "$PGDG_KEY_FINGERPRINT"
  rn "$n" rm -f /etc/apt/sources.list.d/pgdg.list
  CHANGED=0
  put "$n" /etc/apt/sources.list.d/pgdg.sources 644 root:root <<'SRC'
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: trixie-pgdg
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
SRC
  local repo_changed=$CHANGED

  # Debian's postgresql-common creates a "main" cluster when postgresql-NN is
  # installed. create_main_cluster = false in its conffile stops that, also on
  # later package upgrades (apt runs with --force-confold so the local edit
  # survives). Patroni owns the data directory, so no 18/main may exist.
  have="$(rn "$n" dpkg-query -W -f '${Version}' postgresql-common 2>/dev/null || true)"
  if [ -z "$have" ]; then
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-common
    log "$n" "installed postgresql-common"
  fi
  if ! rn "$n" grep -q '^create_main_cluster = false$' /etc/postgresql-common/createcluster.conf; then
    # replace an existing (or commented) line, append when there is none
    rn "$n" sh -c 'f=/etc/postgresql-common/createcluster.conf
      if grep -q "^#\?create_main_cluster" "$f"; then
        sed -i "s/^#\?create_main_cluster.*/create_main_cluster = false/" "$f"
      else
        echo "create_main_cluster = false" >>"$f"
      fi'
    log "$n" "create_main_cluster = false"
  fi

  have="$(rn "$n" dpkg-query -W -f '${Version}' "postgresql-$PG_MAJOR" 2>/dev/null || true)"
  local havep
  havep="$(rn "$n" dpkg-query -W -f '${Version}' patroni 2>/dev/null || true)"
  if [ "$have" != "$PG_PACKAGE_VERSION" ] || [ "$havep" != "$PATRONI_PACKAGE_VERSION" ]; then
    # python3-etcd: Patroni's etcd3 DCS imports it, see lab/stage3/postgres/Dockerfile
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confold \
      "postgresql-$PG_MAJOR=$PG_PACKAGE_VERSION" "patroni=$PATRONI_PACKAGE_VERSION" python3-etcd
    log "$n" "installed postgresql-$PG_MAJOR $PG_PACKAGE_VERSION, patroni $PATRONI_PACKAGE_VERSION"
  elif [ "$repo_changed" = 1 ]; then
    rn "$n" apt-get update -qq
  fi
  # a main cluster from an earlier install (not expected on clean VMs)
  # (output captured first: grep -q closing the pipe early would trip pipefail)
  clusters="$(rn "$n" pg_lsclusters --no-header 2>/dev/null || true)"
  if grep -q "^${PG_MAJOR}[[:space:]]\+main" <<<"$clusters"; then
    rn "$n" pg_dropcluster --stop "$PG_MAJOR" main
    log "$n" "dropped Debian cluster $PG_MAJOR/main"
  fi

  # etcd binaries: GitHub release tarball, checked against the release's
  # SHA256SUMS (same origin as the tarball: protects against corruption, not
  # against a compromised release)
  if [ "$(rn "$n" sh -c "/usr/local/bin/etcd --version 2>/dev/null | sed -n 's/^etcd Version: //p'")" != "$ETCD_VERSION" ]; then
    rn "$n" sh -euc '
      v=$1; t=etcd-v$v-linux-amd64.tar.gz; b=https://github.com/etcd-io/etcd/releases/download/v$v
      d=$(mktemp -d); trap "rm -rf $d" EXIT; cd "$d"
      curl -fsSL -O "$b/$t"; curl -fsSL -O "$b/SHA256SUMS"
      grep " $t\$" SHA256SUMS | sha256sum -c - >/dev/null
      tar -xzf "$t" --strip-components=1 "etcd-v$v-linux-amd64/etcd" "etcd-v$v-linux-amd64/etcdctl" "etcd-v$v-linux-amd64/etcdutl"
      install -m 0755 etcd etcdctl etcdutl /usr/local/bin/' sh "$ETCD_VERSION"
    log "$n" "installed etcd $ETCD_VERSION"
  fi

  # otelcol-contrib: .deb checked against the release's .sha256 file; the
  # package starts and enables the service with its default config, which is
  # replaced and restarted by phase_collector below
  have="$(rn "$n" dpkg-query -W -f '${Version}' otelcol-contrib 2>/dev/null || true)"
  if [ "$have" != "$OTELCOL_VERSION" ]; then
    rn "$n" sh -euc '
      v=$1; f=otelcol-contrib_${v}_linux_amd64.deb
      b=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$v
      d=$(mktemp -d); trap "rm -rf $d" EXIT; cd "$d"
      curl -fsSL -O "$b/$f"; curl -fsSL -O "$b/$f.sha256"
      echo "$(cut -d" " -f1 "$f.sha256")  $f" | sha256sum -c - >/dev/null
      DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold "$f" >/dev/null' sh "$OTELCOL_VERSION"
    log "$n" "installed otelcol-contrib $OTELCOL_VERSION"
  fi
  # etcd user, directories, certificates, unit
  rn "$n" sh -c 'id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /usr/sbin/nologin etcd'
  rn "$n" install -d -m 0700 -o root -g root "$MARK_DIR"
  rn "$n" install -d -m 0700 -o etcd -g etcd /var/lib/etcd
  rn "$n" install -d -m 0750 -o etcd -g etcd /etc/etcd /etc/etcd/tls
  rn "$n" install -d -m 0750 -o postgres -g postgres /etc/patroni /etc/patroni/tls
  CHANGED=0
  putf "$n" /etc/etcd/tls/ca.crt 644 etcd:etcd "$pki/ca.crt" "$ETCD_MARK"
  putf "$n" /etc/etcd/tls/etcd.crt 644 etcd:etcd "$pki/$n/etcd.crt" "$ETCD_MARK"
  putf "$n" /etc/etcd/tls/etcd.key 600 etcd:etcd "$pki/$n/etcd.key" "$ETCD_MARK"
  # etcdctl client cert (root only, used with sudo etcdctl)
  putf "$n" /etc/etcd/tls/etcdctl.crt 644 root:root "$pki/etcdctl.crt" "$ETCD_MARK"
  putf "$n" /etc/etcd/tls/etcdctl.key 600 root:root "$pki/etcdctl.key" "$ETCD_MARK"
  put "$n" /etc/systemd/system/etcd.service 644 root:root "$ETCD_MARK" <<<"${ETCD_UNIT[$n]}"
  # changed now, or left pending by an interrupted run
  ETCD_CHANGED[$n]=$CHANGED
  pending=$(rn "$n" sh -c 'if [ -e "$1" ]; then echo y; else echo n; fi' sh "$ETCD_MARK")
  if [ "$pending" = y ]; then ETCD_CHANGED[$n]=1; fi

  # Patroni: certificates, config, bootstrap script, watchdog rule
  CHANGED=0
  putf "$n" /etc/patroni/tls/ca.crt 644 postgres:postgres "$pki/ca.crt" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/postgres.crt 644 postgres:postgres "$pki/$n/postgres.crt" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/postgres.key 600 postgres:postgres "$pki/$n/postgres.key" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/patroni.crt 644 postgres:postgres "$pki/$n/patroni.crt" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/patroni.key 600 postgres:postgres "$pki/$n/patroni.key" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/etcd-client.crt 644 postgres:postgres "$pki/patroni-etcd.crt" "$PATRONI_MARK"
  putf "$n" /etc/patroni/tls/etcd-client.key 600 postgres:postgres "$pki/patroni-etcd.key" "$PATRONI_MARK"
  putf "$n" /etc/patroni/post-bootstrap.sh 750 postgres:postgres "$files/post-bootstrap.sh" "$PATRONI_MARK"
  # secrets for post-bootstrap.sh, read by systemd (root) via EnvironmentFile
  put "$n" /etc/patroni_env.conf 600 root:root "$PATRONI_MARK" <<<"$PATRONI_ENV"
  put "$n" /etc/patroni/config.yml 600 postgres:postgres "$PATRONI_MARK" <<<"${PATRONI_CONF[$n]}"
  PATRONI_CHANGED[$n]=$CHANGED
  pending=$(rn "$n" sh -c 'if [ -e "$1" ]; then echo y; else echo n; fi' sh "$PATRONI_MARK")
  if [ "$pending" = y ]; then PATRONI_CHANGED[$n]=1; fi

  # watchdog: udev rule, applied to the live device without a reboot
  CHANGED=0
  putf "$n" /etc/udev/rules.d/60-patroni-watchdog.rules 644 root:root "$files/60-patroni-watchdog.rules"
  # Patroni runs with watchdog mode required, so the device must exist
  wd_group="$(rn "$n" stat -c %G /dev/watchdog)" || { echo "[$n] /dev/watchdog missing (watchdog mode is required)" >&2; exit 1; }
  if [ "$CHANGED" = 1 ] || [ "$wd_group" != postgres ]; then
    rn "$n" udevadm control --reload
    rn "$n" udevadm trigger --action=change --subsystem-match=misc --sysname-match=watchdog
    rn "$n" udevadm settle
    log "$n" "watchdog rule applied: $(rn "$n" stat -c '%U:%G %a' /dev/watchdog)"
  fi
}

# Fail closed: render everything for every node before the first write. A
# failing assignment stops the script here (set -e, inherit_errexit); the
# here-string in put adds back the newline that $(...) strips.
for key in POSTGRES_PASSWORD REPLICATOR_PASSWORD OTEL_MONITOR_PASSWORD APP_PASSWORD PATRONI_API_PASSWORD; do
  [ -n "${!key:-}" ] || { echo "$key missing or empty in lab/pgha/.env" >&2; exit 1; }
done
PATRONI_ENV="$(printf 'OTEL_MONITOR_PASSWORD=%s\nAPP_PASSWORD=%s' "$OTEL_MONITOR_PASSWORD" "$APP_PASSWORD")"
for n in $want; do
  ETCD_UNIT[$n]="$(render "$files/etcd.service.tmpl" "$n")"
  PATRONI_CONF[$n]="$(render "$files/patroni.yml.tmpl" "$n")"
  OTEL_CONF[$n]="$(render "$files/otelcol.yaml.tmpl" "$n")"
done
for n in $want; do phase_base "$n"; done

# etcd: Type=notify blocks until a quorum exists, so start without waiting and
# poll afterwards
etcd_health() { rn "$1" etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/etcd/tls/ca.crt \
  --cert=/etc/etcd/tls/etcdctl.crt --key=/etc/etcd/tls/etcdctl.key "${@:2}"; }
# wait_etcd NODE [--cluster]: fail after 120 s
wait_etcd() {
  local _
  for _ in $(seq 1 60); do
    if etcd_health "$1" endpoint health ${2:+"$2"} >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "etcd ${2:+cluster }on $1 not healthy after 120 s" >&2
  exit 1
}
# 1. start every inactive member first (an inactive member would fail the
#    cluster health check that guards each restart below)
started=""
for n in $want; do
  if [ "$(rn "$n" systemctl is-active etcd || true)" != active ]; then
    rn "$n" systemctl daemon-reload
    rn "$n" systemctl enable etcd >/dev/null 2>&1
    rn "$n" systemctl start --no-block etcd
    log "$n" "etcd started"
    started="$started $n"
  fi
done
for n in $started; do wait_etcd "$n" --cluster; rn "$n" rm -f "$ETCD_MARK"; done
# 2. rolling restart of changed or pending members: one at a time, and only
#    while the whole cluster is healthy, so a config change never takes away
#    the quorum Patroni needs. The marker goes after the post-restart check.
for n in $want; do
  case " $started " in *" $n "*) continue ;; esac
  if [ "${ETCD_CHANGED[$n]}" = 1 ]; then
    wait_etcd "$n" --cluster
    rn "$n" systemctl daemon-reload
    rn "$n" systemctl restart etcd
    log "$n" "etcd restarted (config changed)"
    wait_etcd "$n" --cluster
    rn "$n" rm -f "$ETCD_MARK"
  fi
done
for n in $want; do wait_etcd "$n"; done

# Patroni
for n in $want; do
  if [ "$(rn "$n" systemctl is-enabled patroni 2>/dev/null || true)" != enabled ]; then
    rn "$n" systemctl enable patroni >/dev/null 2>&1
  fi
  if [ "$(rn "$n" systemctl is-active patroni || true)" != active ]; then
    rn "$n" systemctl start --no-block patroni
    rn "$n" rm -f "$PATRONI_MARK"
    log "$n" "patroni started"
  elif [ "${PATRONI_CHANGED[$n]}" = 1 ]; then
    # SIGHUP reload; settings that need a PostgreSQL restart show up as
    # "pending restart" in patronictl list and are not restarted here
    rn "$n" systemctl reload patroni
    rn "$n" rm -f "$PATRONI_MARK"
    log "$n" "patroni reloaded (config changed)"
  fi
done
# Per-node Collector: config, certificates, pack, secret and systemd drop-in,
# then enable and restart only when one of them changed (marker as for etcd).
# Runs after Patroni. On a fresh install the otel_monitor role can still be
# missing for a while (Patroni starts with --no-block); the Collector logs
# authentication errors and retries until post-bootstrap has created it.
phase_collector() {
  local n="$1" pending changed=0 state
  # root:otelcol-contrib 0750: the service user reads, nobody else
  rn "$n" install -d -m 0750 -o root -g otelcol-contrib /etc/otelcol-contrib \
    /etc/otelcol-contrib/tls /etc/otelcol-contrib/packs /etc/otelcol-contrib/packs/postgresql
  rn "$n" install -d -m 0755 -o root -g root /etc/systemd/system/otelcol-contrib.service.d
  CHANGED=0
  putf "$n" /etc/otelcol-contrib/tls/ca.crt 644 root:otelcol-contrib "$pki/ca.crt" "$OTEL_MARK"
  putf "$n" /etc/otelcol-contrib/tls/otelcol.crt 644 root:otelcol-contrib "$pki/$n/otelcol.crt" "$OTEL_MARK"
  putf "$n" /etc/otelcol-contrib/tls/otelcol.key 600 otelcol-contrib:otelcol-contrib "$pki/$n/otelcol.key" "$OTEL_MARK"
  putf "$n" /etc/otelcol-contrib/packs/postgresql/queries.yaml 644 root:otelcol-contrib "$dir/../packs/postgresql/queries.yaml" "$OTEL_MARK"
  # root-only; systemd reads it (EnvironmentFile in the drop-in), the service
  # user never opens it and the value is not in the config or on any command line
  put "$n" /etc/otelcol-contrib/monitor.env 600 root:root "$OTEL_MARK" <<<"OTEL_MONITOR_PASSWORD=$OTEL_MONITOR_PASSWORD"
  putf "$n" /etc/systemd/system/otelcol-contrib.service.d/obenhub.conf 644 root:root "$files/otelcol.service-dropin.conf" "$OTEL_MARK"
  put "$n" /etc/otelcol-contrib/config.yaml 640 root:otelcol-contrib "$OTEL_MARK" <<<"${OTEL_CONF[$n]}"
  changed=$CHANGED
  pending=$(rn "$n" sh -c 'if [ -e "$1" ]; then echo y; else echo n; fi' sh "$OTEL_MARK")
  if [ "$pending" = y ]; then changed=1; fi
  # warn only: with the backend down the Collector retries by itself
  if ! rn "$n" timeout 5 bash -c "exec 3<>/dev/tcp/$GATEWAY_IP/$GATEWAY_PORT" 2>/dev/null; then
    log "$n" "WARNING: gateway $GATEWAY_IP:$GATEWAY_PORT not reachable (is lab:pgha:mon:up running?)"
  fi
  state=$(rn "$n" systemctl is-active otelcol-contrib || true)
  if [ "$state" != active ] || [ "$changed" = 1 ]; then
    rn "$n" systemctl daemon-reload
    rn "$n" systemctl enable otelcol-contrib >/dev/null 2>&1
    rn "$n" systemctl restart otelcol-contrib
    sleep 5
    if [ "$(rn "$n" systemctl is-active otelcol-contrib || true)" != active ]; then
      echo "[$n] otelcol-contrib not active after restart" >&2
      rn "$n" journalctl -u otelcol-contrib -n 20 --no-pager >&2 || true
      exit 1
    fi
    rn "$n" rm -f "$OTEL_MARK"
    log "$n" "otelcol-contrib (re)started"
  elif [ "$(rn "$n" systemctl is-enabled otelcol-contrib 2>/dev/null || true)" != enabled ]; then
    rn "$n" systemctl enable otelcol-contrib >/dev/null 2>&1
  fi
}
for n in $want; do phase_collector "$n"; done

# Fault-scenario support: nftables (the scenarios add and delete the table
# "inet obenhub_fault" themselves; Debian's default /etc/nftables.conf is
# left alone) and the client load unit (files/load.sh), which writes through
# the local socket only while the node is the primary. The unit is restarted
# only when the script or the unit file changed.
phase_scenarios() {
  local n="$1" changed=0
  if ! rn "$n" dpkg-query -W -f '${Status}' nftables 2>/dev/null | grep -q 'install ok installed'; then
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    rn "$n" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables
    log "$n" "installed nftables"
  fi
  CHANGED=0
  putf "$n" /usr/local/bin/obenhub-load.sh 755 root:root "$files/load.sh"
  putf "$n" /etc/systemd/system/obenhub-load.service 644 root:root "$files/obenhub-load.service"
  changed=$CHANGED
  if [ "$changed" = 1 ]; then rn "$n" systemctl daemon-reload; fi
  if [ "$(rn "$n" systemctl is-enabled obenhub-load 2>/dev/null || true)" != enabled ]; then
    rn "$n" systemctl enable obenhub-load >/dev/null 2>&1
  fi
  if [ "$(rn "$n" systemctl is-active obenhub-load || true)" != active ]; then
    rn "$n" systemctl start obenhub-load
    log "$n" "obenhub-load started"
  elif [ "$changed" = 1 ]; then
    rn "$n" systemctl restart obenhub-load
    log "$n" "obenhub-load restarted (changed)"
  fi
}
for n in $want; do phase_scenarios "$n"; done

first="${want%% *}"
for _ in $(seq 1 90); do
  out=$(rn "$first" sudo -u postgres patronictl -c /etc/patroni/config.yml list 2>/dev/null || true)
  if grep -q Leader <<<"$out"; then printf '%s\n' "$out"; exit 0; fi
  sleep 2
done
echo "no Patroni leader after 180 s" >&2
exit 1
