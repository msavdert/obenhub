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
| `oracle/monitoring-user.sql` | the two Oracle monitoring users and their grants, run by a DBA with `sqlplus` ([guide page](../docs/guides/monitor/oracle.md)) |
| `collector/obenhub-oracle.env.example` | variables of a Collector that monitors an Oracle CDB ([guide page](../docs/guides/monitor/oracle.md)) |
| `helm/agent-values.yaml`, `helm/cnpg-values.yaml`, `helm/cluster-values.yaml`, `helm/versions.sh` | values for the `opentelemetry-collector` chart (the agent for any PostgreSQL pod, the CloudNativePG additions, the cluster-wide Collector), and its pin |

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

Under systemd the upstream package's own unit runs it: the `--config` list is
`OTELCOL_OPTIONS` in `/etc/otelcol-contrib/otelcol-contrib.conf` and a drop-in
adds `obenhub.env`, a state directory and the journal group.
[The VM page of the guide](../docs/guides/monitor/vm.md) lists the steps and
the permissions, and `mise run deploy:vm-test` runs them on a second machine.

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

## VM test

`mise run deploy:vm-test` (docker and ssh, about 20 minutes, not part of
`mise run check`) starts the same kind of backend in a throwaway compose
project on this machine and, on an ssh target (default `pg-lab`, Debian), makes
a PostgreSQL cluster with `pg_createcluster` and its defaults, installs the
upstream `otelcol-contrib` `.deb` of the gateway's version after checking its
`.sha256`, and runs it under the package's unit as the guide's VM page says. The
assertions and the panel rules are those of the install test
(`deploy/test/lib.sh`), plus: systemd must not have restarted the unit, and the
journal records of the Collector's own unit must be in VictoriaLogs. The
Collector reads the host itself (no `root_path`, no overlay), so the host
dashboard shows the target. PostgreSQL log collection is not exercised (Debian
writes plain stderr logs, not jsonlog). On exit it undoes only what it did on
the target (purge, its files, user and group, its cluster) and a failed teardown
fails the run. Its read-only preflight refuses a target that has a cluster
`18/vmtest`, the package, a listener on 5433, a work directory or a stale
`*.vm-test-aside`, whatever the flags; a leftover `/etc/otelcol-contrib`,
`/var/lib/otelcol-contrib` or drop-in directory is moved aside and back only
with `--force`. It appends a line with `"test": "vm-test"` to
`results/runs.jsonl`.

## Oracle test

`mise run deploy:oracle-test` (docker, about 25 minutes, 4 GiB of free memory,
not part of `mise run check`) is the install test of the
[Oracle page](../docs/guides/monitor/oracle.md), which describes what it runs,
what it asserts, which panels stay empty and why, and the licence of the Oracle
Free image it pulls. It appends a line with `"test": "oracle-test"` to
`results/runs.jsonl`.

## Kubernetes

The values are derived from the kind lab (`lab/k8s/otel/`). The variables in
their headers, the objects to create first and the helm commands are on the
guide's page [PostgreSQL on Kubernetes](../docs/guides/monitor/kubernetes.md),
which `deploy/test/k8s-test.sh` runs (`mise run deploy:k8s-test -- sts` or
`-- cnpg`, about 30 minutes, appends a line with `"test": "k8s-sts-test"` or
`"k8s-cnpg-test"` to `results/runs.jsonl`). Rendering was also checked with
`helm template` (chart version in `helm/versions.sh`); it needs the network, so
it is not part of `mise run check`.
