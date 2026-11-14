#!/usr/bin/env bash
# Install or converge otelcol-contrib on the observer VM (lab/oracle/pair.sh,
# OBSERVER_HOST) from this box over ssh, ADR 0008 decision 2:
#   - the otelcol-contrib .rpm of OTELCOL_VERSION (lab/pgha/versions.sh, the
#     one pin all labs share), from opentelemetry-collector-releases, checked
#     against the release's .sha256 file; skipped when that version is installed;
#   - files/otelcol-obs.yaml as the configuration, the oracledb-dg pack it
#     reads, and the client certificate for the gateway (lab/oracle/pki, made
#     by scripts/pki.sh);
#   - a root-only environment file (ORA_MON_PASSWORD, ORA_DG_PASSWORD with the
#     30 characters Oracle uses, see provision.sh; OBENHUB_GATEWAY_ENDPOINT
#     from gateway.sh) that systemd reads through a drop-in; the service user
#     never opens it and no value is on a command line or in the config;
#   - a restart only when the package or one of those files changed, or the
#     service is not active; the run fails unless it stays active.
# Usage: collector.sh
# Idempotent: every file is replaced only when its content, mode or owner
# differs. Needs lab/oracle/.env (provision.sh creates it) and lab/oracle/pki
# (scripts/pki.sh; run `mise run lab:oracle:mon:up` or `lab:oracle:pki` first).
# Assumes: the ssh alias of pair.sh, a user with passwordless sudo, Oracle
# Linux 9 (rpm; the unit file comes from the package) with outbound HTTPS to
# the release host.
# shellcheck disable=SC2016,SC2029  # remote command lines are built here on purpose
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/pair.sh"
# shellcheck source=/dev/null
. "$dir/gateway.sh"
# shellcheck source=/dev/null
. "$dir/../pgha/versions.sh"

pki="$dir/pki"
n="$OBSERVER_HOST"
for f in "$dir/.env" "$pki/ca.crt" "$pki/otelcol.crt" "$pki/otelcol.key" \
  "$dir/files/otelcol-obs.yaml" "$dir/../packs/oracledb-dg/queries.yaml"; do
  [ -s "$f" ] || { echo "collector: $f is missing (provision.sh, pki.sh)" >&2; exit 1; }
done
set -a
# shellcheck source=/dev/null
. "$dir/.env"
set +a
MON_PW=${ORA_MON_PASSWORD:-}
DG_PW=${ORA_DG_PASSWORD:-}
MON_PW=${MON_PW:0:30}
DG_PW=${DG_PW:0:30}
for pw in "$MON_PW" "$DG_PW"; do
  case "$pw" in *[!0-9a-f]*|"") echo "collector: passwords in .env must be hex (gen-env.sh)" >&2; exit 1 ;; esac
  [ "${#pw}" -eq 30 ] || { echo "collector: passwords in .env must have at least 30 characters" >&2; exit 1; }
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
MARK=/var/lib/obenhub-oracle/otelcol.restart-pending
CHANGED=0
# rn <command...>: run a command as root on the observer; ssh joins its
# arguments into one command line, so quote each one
rn() { ssh "${SSH_OPTS[@]}" "$n" "sudo $(printf '%q ' "$@")"; }
log() { echo "[$1] $2"; }

# put <dest> <mode> <owner> < content: replace dest when content, mode or owner
# differ (written beside it, then renamed), and set the restart marker. The
# content reaches the VM on stdin only. Same as put() in lab/pgha/scripts/provision.sh.
put() {
  local out content LC_ALL=C
  IFS= read -r -d '' content || true
  if [ -z "${content//[[:space:]]/}" ]; then echo "[$n] refusing to write empty $1" >&2; return 1; fi
  out="$(printf '%s' "$content" | rn sh -c '
    t=$(mktemp "$1.XXXXXX") || exit 1
    trap "rm -f \"$t\"" EXIT HUP INT TERM
    cat >"$t" && chown "$3" "$t" && chmod "$2" "$t" || exit 1
    [ "$(wc -c <"$t")" = "$5" ] || { echo "short write to $1" >&2; exit 1; }
    if [ -e "$1" ] && cmp -s "$t" "$1" && [ "$(stat -c %a:%U:%G "$1")" = "$2:$3" ]; then
      echo same
    else
      : >"$4" || exit 1
      mv "$t" "$1" || exit 1; echo changed
    fi' sh "$1" "$2" "$3" "$MARK" "${#content}")"
  if [ "$out" = changed ]; then CHANGED=1; log "$n" "updated $1"; fi
}
# putf <dest> <mode> <owner> <local file>
putf() { put "$1" "$2" "$3" <"$4"; }

# --- package -----------------------------------------------------------------
rn install -d -m 0700 -o root -g root "$(dirname "$MARK")"
have="$(rn rpm -q --qf '%{VERSION}' otelcol-contrib 2>/dev/null || true)"
case "$have" in [0-9]*) ;; *) have="" ;; esac  # rpm -q prints "not installed" on stdout
if [ "$have" != "$OTELCOL_VERSION" ]; then
  rn sh -euc '
    v=$1; f=otelcol-contrib_${v}_linux_amd64.rpm
    b=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$v
    d=$(mktemp -d); trap "rm -rf \"\${d:?}\"" EXIT; cd "$d"
    curl -fsSL -O "$b/$f"; curl -fsSL -O "$b/$f.sha256"
    echo "$(cut -d" " -f1 "$f.sha256")  $f" | sha256sum -c - >/dev/null
    rpm -U --oldpackage --quiet "$f"' sh "$OTELCOL_VERSION"
  rn sh -c ': >"$1"' sh "$MARK"
  log "$n" "installed otelcol-contrib $OTELCOL_VERSION${have:+ (was $have)}"
fi

# --- configuration -----------------------------------------------------------
# root:otelcol-contrib 0750: the service user reads, nobody else
rn install -d -m 0750 -o root -g otelcol-contrib /etc/otelcol-contrib \
  /etc/otelcol-contrib/tls /etc/otelcol-contrib/packs /etc/otelcol-contrib/packs/oracledb-dg
rn install -d -m 0755 -o root -g root /etc/systemd/system/otelcol-contrib.service.d
putf /etc/otelcol-contrib/tls/ca.crt 640 root:otelcol-contrib "$pki/ca.crt"
putf /etc/otelcol-contrib/tls/otelcol.crt 640 root:otelcol-contrib "$pki/otelcol.crt"
putf /etc/otelcol-contrib/tls/otelcol.key 600 otelcol-contrib:otelcol-contrib "$pki/otelcol.key"
putf /etc/otelcol-contrib/packs/oracledb-dg/queries.yaml 640 root:otelcol-contrib "$dir/../packs/oracledb-dg/queries.yaml"
putf /etc/otelcol-contrib/config.yaml 640 root:otelcol-contrib "$dir/files/otelcol-obs.yaml"
put /etc/otelcol-contrib/obenhub.env 600 root:root <<ENV
ORA_MON_PASSWORD=$MON_PW
ORA_DG_PASSWORD=$DG_PW
OBENHUB_GATEWAY_ENDPOINT=https://$GATEWAY_IP:$GATEWAY_PORT
ENV
put /etc/systemd/system/otelcol-contrib.service.d/obenhub.conf 644 root:root <<'UNIT'
# Installed by lab/oracle/scripts/collector.sh. The environment file is
# root-only and read by systemd itself.
[Service]
EnvironmentFile=/etc/otelcol-contrib/obenhub.env
UNIT

# the package options file must point at the config written above (seen in the
# 0.164.0 rpm: OTELCOL_OPTIONS="--config=/etc/otelcol-contrib/config.yaml")
if ! rn grep -q -- "--config=/etc/otelcol-contrib/config.yaml" /etc/otelcol-contrib/otelcol-contrib.conf; then
  echo "[$n] otelcol-contrib.conf does not point at /etc/otelcol-contrib/config.yaml; check the package" >&2
  exit 1
fi

# warn only: with the backend down the exporter retries by itself
if ! rn timeout 5 bash -c "exec 3<>/dev/tcp/$GATEWAY_IP/$GATEWAY_PORT" 2>/dev/null; then
  log "$n" "WARNING: gateway $GATEWAY_IP:$GATEWAY_PORT not reachable (is lab:oracle:mon:up running?)"
fi

# --- service -----------------------------------------------------------------
changed=$CHANGED
if rn test -e "$MARK"; then changed=1; fi
state=$(rn systemctl is-active otelcol-contrib || true)
if [ "$state" != active ] || [ "$changed" = 1 ]; then
  rn systemctl daemon-reload
  rn systemctl enable otelcol-contrib >/dev/null 2>&1
  rn systemctl restart otelcol-contrib
  # Three active samples 2 s apart within 30 s, NRestarts and ActiveEnterTimestamp
  # unchanged between the first and the last (as lab/pgha/scripts/provision.sh):
  # a slow crash loop can look active on every sample but moves one of them.
  # first_props is the first active sample ever, kept across a non-active one,
  # so a crash and recovery inside the window fails the check too.
  ok=0 first_props="" last_props=""
  for _ in $(seq 1 15); do
    last_props=$(rn systemctl show -p NRestarts -p ActiveEnterTimestamp -p ActiveState otelcol-contrib || true)
    if grep -qx 'ActiveState=active' <<<"$last_props"; then
      ok=$((ok + 1))
      if [ -z "$first_props" ]; then first_props="$last_props"; fi
    else
      ok=0
    fi
    if [ "$ok" -ge 3 ]; then break; fi
    sleep 2
  done
  if [ "$ok" -lt 3 ] || [ "$first_props" != "$last_props" ]; then
    echo "[$n] otelcol-contrib not stably active within 30 s of the restart (restarted or flapping)" >&2
    rn journalctl -u otelcol-contrib -n 20 --no-pager >&2 || true
    exit 1
  fi
  rn rm -f "$MARK"
  log "$n" "otelcol-contrib (re)started"
else
  if [ "$(rn systemctl is-enabled otelcol-contrib 2>/dev/null || true)" != enabled ]; then
    rn systemctl enable otelcol-contrib >/dev/null 2>&1
    log "$n" "otelcol-contrib enabled"
  fi
  log "$n" "otelcol-contrib $OTELCOL_VERSION unchanged, active, not restarted"
fi
