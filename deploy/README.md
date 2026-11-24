# deploy

The install path outside the labs: the backend and gateway in Docker Compose,
a Collector configuration for a host, and values for the upstream Collector
Helm chart. It runs the same images as the labs (`mise run lint:deploy-pins`
fails when they differ). This page lists what is here and the commands.

| Path | What |
| --- | --- |
| `compose/compose.yaml` | VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager, Grafana and the mutual-TLS gateway Collector |
| `compose/tls.sh` | CA, gateway certificate and one client certificate (openssl) into `compose/tls/` |
| `compose/inventory.yml` | what you expect to see (Collectors, databases); an example you edit |
| `compose/alertmanager.yml` | routes by severity, a dead-man route for `Watchdog` |
| `collector/otelcol-tls.yaml`, `collector/obenhub.env.example` | mutual-TLS overlay and variables of a host Collector |
| `helm/agent-values.yaml`, `helm/cluster-values.yaml`, `helm/versions.sh` | values for the `opentelemetry-collector` chart, and its pin |

Prerequisites: Docker with the Compose plugin, bash 4+ and OpenSSL 1.1.1+
(not LibreSSL: `tls.sh` uses `-addext`) on the backend
machine (a checkout of this repository, because Compose mounts `packs/`); on
a database host the `otelcol-contrib` binary of the same version as the
gateway image (see `compose/compose.yaml`); for Kubernetes, `helm` and
`envsubst`.

## Backend

```sh
cd deploy/compose
bash tls.sh gateway.example.net 192.0.2.10      # DNS names and IPs hosts will use to reach the gateway
cp .env.example .env                            # set GRAFANA_ADMIN_PASSWORD, OBENHUB_UID, OBENHUB_GID
docker compose up -d --wait
```

Grafana is at `http://127.0.0.1:3000` (user `admin`, anonymous access off).
Every port but the gateway's listens on `127.0.0.1` (`OBENHUB_BIND`). Edit
`inventory.yml` to name your Collectors and databases, then
`docker compose kill -s SIGHUP vmalert`. The packs' alerts use their
production defaults: no `*-parameters` group is loaded.

Alertmanager delivers every notification to VictoriaLogs and nowhere else
until you uncomment a `url_file` webhook in `alertmanager.yml`. Point the
`deadman` receiver at a heartbeat service that alerts when `Watchdog` stops
arriving (it is sent every 60 s: six consecutive notifications measured 60 s apart, see
the comment on the route; the URL goes in `compose/secrets/deadman.url`,
gitignored, mounted by the commented volume in `compose.yaml`; the file must be
readable by the container user, mode 0644; a 0600 file is not read).

## Host Collector

The fragments read their query files from `/etc/otelcol-contrib/packs/<pack>/`,
so install the repository files there. On each database host, as root:

```sh
install -d /etc/otelcol-contrib/packs /etc/otelcol-contrib/tls
cp packs/otelcol-base.yaml /etc/otelcol-contrib/packs/
for p in collector host postgresql; do cp -r "packs/$p" /etc/otelcol-contrib/packs/; done   # plus pgbouncer, patroni, etcd, pgbackrest if used
cp deploy/collector/otelcol-tls.yaml /etc/otelcol-contrib/
cp deploy/collector/obenhub.env.example /etc/otelcol-contrib/obenhub.env   # fill it in; mode 0600
# ca.crt, client.crt and client.key from compose/tls/ of the backend machine:
cp ca.crt client.crt client.key /etc/otelcol-contrib/tls/                  # OBENHUB_TLS_DIR in obenhub.env
```

`obenhub.env` has every variable (`packs/<pack>/README.md`, "Collector
fragment", explains each); the PostgreSQL role is
`packs/postgresql/monitoring-role.sql`. Then:

```sh
set -a; . /etc/otelcol-contrib/obenhub.env; set +a
otelcol-contrib \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml
```

Add the `otelcol.yaml` of `pgbouncer`, `patroni`, `etcd` or `pgbackrest`
before the TLS overlay, which comes last because it replaces the
self-telemetry reader of the collector pack. `mise run lint:otelcol`
validates and starts exactly this combination (from the repository paths).

## Install test

`mise run deploy:install-test` (docker, about 15 minutes, not part of
`mise run check`) installs this page's backend and host Collector in a
throwaway compose project against a plain PostgreSQL container with default
settings, without lab files (Grafana's provisioning from `lab/mon/` is the
one exception, see `compose.yaml`). It waits past the longest `for:` of the
packs that can fire on this setup (collector, host, postgresql), then
asserts that the heartbeat is there, that only `Watchdog` fires with nothing
pending, that no other alert fired at any time during the run (the one
exception is `CollectorAbsent` of the host Collector in its first 120 s: the
inventory expects it before its first export has arrived), that `Watchdog`
reaches the `deadman` receiver every 60 s with the newest notification at
most 90 s old, and that every panel of the PostgreSQL and host dashboards is
accounted for and returns data or is empty for a known reason. The panels
that stay empty are the rows of components only some labs run (subscription,
PgBouncer, pgBackRest), the log and scenario-only panels, and the replication
slot panels (a plain server has none). journald and PostgreSQL log
collection are not exercised (no `journalctl` in the contrib image, no
jsonlog on a default server). The Collector runs in a container with the
host's `/` mounted read-only and `root_path` set in a test overlay, which the
host pack does not do itself; with real filesystem data `HostFilesystemSpaceLow`
fires on a nearly full host, which is a correct report and makes the test
fail there (machine-dependent).
Everything is torn down, and a line goes to `results/runs.jsonl`.

## Kubernetes

The values are derived from the kind lab (`lab/k8s/otel/`) and are for
CloudNativePG clusters; the variables in their header are filled by
`envsubst`.

```sh
. deploy/helm/versions.sh
export OTELCOL_IMAGE_REPOSITORY="${OTELCOL_IMAGE%%:*}" OTELCOL_IMAGE_DIGEST="${OTELCOL_IMAGE#*@}"
r="${OTELCOL_IMAGE#*:}"; export OTELCOL_IMAGE_TAG="${r%%@*}"
export OBENHUB_GATEWAY_ENDPOINT=https://gateway.example.net:4318 OBENHUB_SERVICE_NAMESPACE=obenhub \
  OBENHUB_CLUSTER_NAME=pg OBENHUB_PG_NAMESPACE=db OBENHUB_OTEL_NAMESPACE=obenhub-otel \
  OBENHUB_PG_DATABASES='[postgres, app]' OBENHUB_PG_SLOW_DATABASE=app
vars='$OBENHUB_GATEWAY_ENDPOINT $OBENHUB_SERVICE_NAMESPACE $OBENHUB_CLUSTER_NAME $OBENHUB_PG_NAMESPACE $OBENHUB_OTEL_NAMESPACE $OBENHUB_PG_DATABASES $OBENHUB_PG_SLOW_DATABASE $OTELCOL_IMAGE_REPOSITORY $OTELCOL_IMAGE_TAG $OTELCOL_IMAGE_DIGEST'
helm repo add otel "$OTEL_CHART_REPO"
for n in agent cluster; do
  envsubst "$vars" < "deploy/helm/$n-values.yaml" |
    helm upgrade --install "$n" otel/opentelemetry-collector --version "$OTEL_CHART_VERSION" \
      -n "$OBENHUB_OTEL_NAMESPACE" --create-namespace -f -
done
```

`OBENHUB_OTEL_NAMESPACE` is where the release goes; `OBENHUB_PG_DATABASES`
is the list of databases to monitor and `OBENHUB_PG_SLOW_DATABASE` the one
database the slow tier (autovacuum backlog, every 5 minutes) reads; it is
required here, since envsubst leaves an unset variable empty and the
Collector then refuses the receiver. Create the namespace and, in it, before
the install: the secret `obenhub-gateway-tls`
(`ca.crt`, `tls.crt` = `client.crt`, `tls.key` = `client.key`), the secret
`pg-otel-monitor` (key `password`), the ConfigMap `obenhub-pack-postgresql`
(`packs/postgresql/queries.yaml` and `queries-slow.yaml`) and the ConfigMap `obenhub-pg-ca` (`ca.crt`
of the PostgreSQL server certificates). Rendering was checked with `helm
template` (chart version in `helm/versions.sh`); it needs the network, so it
is not part of `mise run check`.
