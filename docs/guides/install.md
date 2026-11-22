# Install against your PostgreSQL

How to install the `deploy/` files of obenhub against a PostgreSQL server you
already run, without the lab: the backend (VictoriaMetrics, VictoriaLogs,
vmalert, Alertmanager, Grafana and a mutual-TLS gateway Collector) in Docker
Compose, and a Collector on the database host. This guide follows what
`mise run deploy:install-test` does and checks
([`deploy/test/install-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/install-test.sh)),
so each step names the evidence for it. The reference for every file is
[`deploy/README.md`](https://github.com/msavdert/obenhub/blob/main/deploy/README.md).
To see an alert fire first, do the [quick start](quick-start.md).

What the install test proves, and what it does not. The latest run
(2026-11-20, commit 119ff5c, clean tree, line in `deploy/results/runs.jsonl`)
passed in 844 s against a plain `postgres:18.7` container with default settings:
the heartbeat of the database was in VictoriaMetrics, nothing but `Watchdog`
fired after a 720 s settle, the dead-man receiver got `Watchdog` every 60 s, and
28 dashboard panels had data (15 are empty by design, 2 replication slot panels
are accepted empty because a plain server has none). It does not exercise
journald or PostgreSQL log collection, a Collector running as a host binary (the
test runs the Collector image in a container, as `mise run lint:otelcol` does),
a database on another machine, or any pack but collector, host and postgresql.
Where this guide goes beyond that, the step says so.

## What you need

- A backend machine with Docker and the Compose plugin ([quick start, step
  1](quick-start.md#1-docker-engine-with-the-compose-plugin)), bash 4 or later,
  OpenSSL 1.1.1 or later (not LibreSSL: `tls.sh` uses `-addext`), `curl`, `jq`
  and a checkout of the repository, because Compose mounts `packs/` and
  `lab/mon/grafana/provisioning` from it:
  `git clone https://github.com/msavdert/obenhub`.
- A PostgreSQL server and a superuser connection to it (`psql`), and a host that
  can reach the server, running the Collector. In the test the host and the
  backend are one machine and the server is a container; separate machines are
  the intended layout and are not tested.
- Free ports 3000, 8428, 8880, 9093 and 9428 on `127.0.0.1` of the backend
  machine, and 4318 (the gateway, on all interfaces by default). They are
  variables in `deploy/compose/.env` (`OBENHUB_*_PORT`, `OBENHUB_BIND`,
  `OBENHUB_GATEWAY_BIND`); the test moves them to `INSTALL_TEST_PORT_BASE`
  (61000) and up.

## 1. The backend

On the backend machine, from the repository:

```sh
cd deploy/compose
bash tls.sh gateway.example.net
cp .env.example .env
sed -i \
  -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 12)/" \
  -e "s/^OBENHUB_UID=.*/OBENHUB_UID=$(id -u)/" \
  -e "s/^OBENHUB_GID=.*/OBENHUB_GID=$(id -g)/" .env
docker compose up -d --wait
```

- `tls.sh` takes the DNS names and IP addresses the Collectors will use to reach
  the gateway (replace `gateway.example.net`; give several, separated by
  spaces). It writes a CA, the gateway certificate and one client certificate to
  `deploy/compose/tls/` (git ignores it). The test passes `gateway`, the
  container's network alias.
- `.env` needs three values and the test sets exactly these (plus the ports and
  the gateway bind address, which it moves to `127.0.0.1`):
  the Grafana admin password, and the user and group id of the user who ran
  `tls.sh`, because the gateway container must read the keys. The
  `sed` above is the test's, with the random password generated the way the test
  does. Read the password later from `.env`.
- `docker compose up -d --wait` returns when every service is healthy. In the
  test this step is the `backend: docker compose up` line.

What the packs' alerts use: production defaults. No `*-parameters` group is
loaded, so thresholds are the pack's, not the lab's shortened ones.

## 2. The monitoring role on your PostgreSQL

The Collector logs in as `otel_monitor`. The role is created by
`packs/postgresql/monitoring-role.sql`; the password is passed as a psql
variable read from the environment, so it is in neither the command line nor a
file:

```sh
export OTEL_MONITOR_PASSWORD="$(openssl rand -hex 12)"
psql -h <server> -U postgres -v ON_ERROR_STOP=1 -q \
  -c '\getenv mon_pw OTEL_MONITOR_PASSWORD' \
  -f packs/postgresql/monitoring-role.sql
```

Run it from the repository root. The test runs the same file the same way
(`psql` inside the server container, file on standard input) and fails on an
error. The script is safe to run again: an existing role keeps its grants and
gets the new password. Keep `OTEL_MONITOR_PASSWORD` in your shell for step 3.
The statements carry the password; the labs silence statement logging and
`pg_stat_statements` for that session, the test does not (the file's header
says so).

## 3. The Collector on the database host

The Collector fragments read their query files from
`/etc/otelcol-contrib/packs/<pack>/`, so the files go there. As root on the
database host, from a checkout of the repository. This is the layout of the
test (collector, host and postgresql packs):

```sh
install -d /etc/otelcol-contrib/packs /etc/otelcol-contrib/tls
cp packs/otelcol-base.yaml /etc/otelcol-contrib/packs/
for p in collector host postgresql; do cp -r "packs/$p" /etc/otelcol-contrib/packs/; done
cp deploy/collector/otelcol-tls.yaml /etc/otelcol-contrib/
cp deploy/collector/obenhub.env.example /etc/otelcol-contrib/obenhub.env
chmod 0600 /etc/otelcol-contrib/obenhub.env
```

Copy `ca.crt`, `client.crt` and `client.key` from `deploy/compose/tls/` of the
backend machine to `/etc/otelcol-contrib/tls/` (never `ca.key`). Then edit
`/etc/otelcol-contrib/obenhub.env`; the test changes these four values and keeps
every other one of the example:

| Variable | Set it to | In the test |
| --- | --- | --- |
| `OBENHUB_GATEWAY_ENDPOINT` | `https://` plus a name given to `tls.sh`, port 4318 | `https://gateway:4318` |
| `OBENHUB_PG_HOST` | the PostgreSQL host the Collector connects to | `pg` |
| `OBENHUB_PG_PASSWORD` | `OTEL_MONITOR_PASSWORD` of step 2 | the generated password |
| `OBENHUB_PG_LOG_GLOB` | where your server writes jsonlog files, or a path that matches nothing | `/nonexistent/postgresql-*.json` (a default server writes no jsonlog) |

The unchanged defaults the test relies on: namespace `obenhub`, collector
instance `otelcol-host-1`, host instance `host-1`, PostgreSQL instance `pg-1` in
cluster `main`, port 5432, user `otel_monitor`, databases `[postgres]`,
`OBENHUB_PG_SSLMODE=disable`. The namespace, the collector instance, the PostgreSQL
instance and the cluster name are the ones `deploy/compose/inventory.yml`
expects (its header says: one host Collector `otelcol-host-1` collecting `pg-1`
of cluster `main`); that file lists what the alerts expect to see, so a
Collector or database you add must be added there too
(`docker compose kill -s SIGHUP vmalert` reloads it). The other variables and
what they mean are in `packs/<pack>/README.md`, "Collector fragment".

Start the Collector with the same version as the gateway image (the `gateway`
service in `deploy/compose/compose.yaml`, `otel/opentelemetry-collector-contrib`
0.165.0 at the time of writing; the file is the authority):

```sh
set -a; . /etc/otelcol-contrib/obenhub.env; set +a
otelcol-contrib \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml
```

The order matters: the TLS overlay comes last. This is `deploy/README.md`,
"Host Collector". The test and `mise run lint:otelcol` run exactly these
arguments in the contrib image, not a host binary; running it as a host binary
or under systemd is unconfirmed (assumption).

## 4. What you should see

Wait before you judge. The test waits 720 s from the Collector's start: the
longest `for:` among the collector, host and postgresql rules is 10 minutes
(`PostgresCollectionIntervalTooLong`, `packs/postgresql/rules.yml`), plus a
120 s margin that is an assumption of the test. Right after the start the
`CollectorAbsent` alert for `otelcol-host-1` may fire, because the inventory
expects a Collector that has not exported yet; the test tolerates it for the
first 120 s only (it was firing for 18 s in the recorded run).

On the backend machine (ports as in `.env`; the defaults are shown):

1. The heartbeat of the database is in VictoriaMetrics, 1 series:

   ```sh
   curl -fsS http://127.0.0.1:8428/api/v1/query \
     --data-urlencode 'query=count(last_over_time({__name__="postgresql.collection.heartbeat","service.instance.id"="pg-1","obenhub.cluster.name"="main"}[2m]))' \
     | jq -r '.data.result[0].value[1]'
   ```

   Expected output: `1`.

2. Only `Watchdog` fires and nothing is pending:

   ```sh
   curl -fsS http://127.0.0.1:8880/api/v1/alerts \
     | jq -r '.data.alerts[] | [.name, .state] | @tsv'
   ```

   Expected output: one line, `Watchdog` and `firing`.

3. `Watchdog` reaches the `deadman` receiver every 60 s. Alertmanager delivers
   every notification to VictoriaLogs and nowhere else until you configure a
   webhook in `deploy/compose/alertmanager.yml`:

   ```sh
   curl -fsS http://127.0.0.1:9428/select/logsql/query \
     --data-urlencode 'query={receiver="deadman"} _time:6m status:firing commonLabels.alertname:Watchdog | sort by (_time)' \
     | jq -r '._time'
   ```

   Expected output: about six timestamps, 60 s apart (the test accepts gaps of
   40 to 80 s, and the newest at most 90 s old).

4. The dashboards have data. Grafana is at `http://127.0.0.1:3000`, user
   `admin`, password `GRAFANA_ADMIN_PASSWORD` of `deploy/compose/.env`; the
   dashboards are "PostgreSQL slice 1" and the host dashboard, provisioned from
   `packs/postgresql/dashboards/postgresql.json` and
   `packs/host/dashboards/host.json`. The test runs every panel query through
   Grafana with the repository's own script; from the repository root:

   ```sh
   scripts/check-panels.sh packs/postgresql/dashboards/postgresql.json \
     http://127.0.0.1:3000 deploy/compose/.env pg-1 main
   scripts/check-panels.sh packs/host/dashboards/host.json \
     http://127.0.0.1:3000 deploy/compose/.env
   ```

   Each panel prints `ok`, `empty` or `FAIL`. Panels are empty by design in rows
   of components only some labs run (subscription, PgBouncer, pgBackRest), in log
   panels and in the panels that only have data during a fault scenario. On a
   server without replication slots the two "Replication slots" panels are
   empty too. (The test accepts exactly those; the script needs `jq` and
   `curl`.)

One caveat from the test's own header: `HostFilesystemSpaceLow` fires on a
nearly full host. That is a correct report, and it makes the test fail on such a
machine.

## 5. Take it down

```sh
cd deploy/compose
docker compose down -v
```

This stops the backend and deletes its volumes. Stop the Collector on the
database host yourself, and drop the `otel_monitor` role if you want it gone
(the test never removes it from a real server: its server is a throwaway
container).

## What the test cleans up and what you keep

The test builds everything in a temporary directory and removes it, the
containers and the network on exit; you are installing for real, so
`deploy/compose/tls/` and `.env` stay. The certificates are modelled on the
labs' PKI with lifetimes chosen by the author (CA 10 years, leaf 2 years, an
assumption recorded in `deploy/compose/tls.sh`); keep `ca.key` off the database
hosts.

## Run the test yourself

```sh
mise run --skip-tools deploy:install-test
```

Needs Docker, `jq`, `curl` and `openssl`, takes about 15 minutes and is not part
of `mise run check`. It appends a line to `deploy/results/runs.jsonl` and prints
a final `install-test: PASS in <n>s, ...` line; set `INSTALL_TEST_EVIDENCE=0` to
skip the line.
