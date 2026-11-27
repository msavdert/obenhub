# Monitor what you already run

How to watch a PostgreSQL you already run with the `deploy/` files of obenhub,
without the lab. One backend (`deploy/compose`: VictoriaMetrics, VictoriaLogs,
vmalert, Alertmanager, Grafana and a mutual-TLS gateway Collector, in Docker
Compose) receives from a Collector next to each database. This page holds what
every target kind shares: the backend, the monitoring role, the changes the
database needs and how to see that it works. Then one page per kind of target:

- [A database on a VM or bare metal](vm.md): the Collector as a host binary
  under systemd, and what `mise run deploy:vm-test` proves.
- [A PostgreSQL container](container.md): the Collector as a container, and
  what `mise run deploy:install-test` proves.
- [PostgreSQL on Kubernetes](kubernetes.md): a StatefulSet with the stock image
  or a CloudNativePG Cluster, the Collector as two Helm releases, and what
  `mise run deploy:k8s-test` proves.

The guide follows what three tests do: the container page what
[`deploy/test/install-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/install-test.sh)
runs, the VM page what
[`deploy/test/vm-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/vm-test.sh)
runs, the Kubernetes page what
[`deploy/test/k8s-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/k8s-test.sh)
runs. Each step names the evidence for it; where it goes beyond the tests, the
step says so. The reference for every file is
[`deploy/README.md`](https://github.com/msavdert/obenhub/blob/main/deploy/README.md).
To see an alert fire first, do the [quick start](../quick-start.md).

## What you need

- A backend machine with Docker and the Compose plugin ([quick start, step
  1](../quick-start.md#1-docker-engine-with-the-compose-plugin)), bash 4 or later,
  OpenSSL 1.1.1 or later (not LibreSSL: `tls.sh` uses `-addext`), `curl`, `jq`
  and a checkout of the repository, because Compose mounts `packs/` and
  `lab/mon/grafana/provisioning` from it:
  `git clone https://github.com/msavdert/obenhub`.
- A PostgreSQL server and a superuser connection to it (`psql`), and a host that
  can reach the server, running the Collector. In the container test the host and
  the backend are one machine and the server is a container. In the VM test the
  database and the Collector are on a second machine, which reaches the backend
  over the network; a server on a third machine than the Collector is not tested.
- Free ports 3000, 8428, 8880, 9093 and 9428 on `127.0.0.1` of the backend
  machine, and 4318 (the gateway, on all interfaces by default). They are
  variables in `deploy/compose/.env` (`OBENHUB_*_PORT`, `OBENHUB_BIND`,
  `OBENHUB_GATEWAY_BIND`); the tests move them to `INSTALL_TEST_PORT_BASE`
  (61000), `VM_TEST_PORT_BASE` (61100) and `K8S_TEST_PORT_BASE` (61200) and up.

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
  `deploy/compose/tls/` (git ignores it). The container test passes `gateway`, the
  container's network alias; the VM test passes the backend's IP address, the one
  the database host connects to. A Collector that runs as a container on the
  backend's Docker network reaches the gateway by that alias, so `gateway` must
  be one of the names too (`bash tls.sh gateway.example.net gateway`); the
  [container page](container.md) says what happens otherwise.
- `.env` needs three values and the tests set exactly these (plus the ports and
  the gateway bind address, which the container test moves to `127.0.0.1` and the
  VM test to the backend's address):
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

Run it from the repository root. The container test runs the same file the same
way (`psql` inside the server container, file on standard input) and fails on an
error; the VM test runs it as the `postgres` user through the local socket
(see the [VM page](vm.md)). The script is safe to run again: an existing role keeps its grants and
gets the new password. Keep `OTEL_MONITOR_PASSWORD` in your shell for the
Collector step. The statements carry the password; the labs silence statement
logging and `pg_stat_statements` for that session, the test does not (the
file's header says so).

## What changes on the database

Everything the monitoring needs from the database you run, and what is lost
without it.

| Change | Required or optional | Without it | Source |
| --- | --- | --- | --- |
| Role `otel_monitor` with `pg_monitor`, `pg_use_reserved_connections` when that role exists (PostgreSQL 16 and later) and `statement_timeout` 5 s, from the script of step 2 | Required | No monitoring login, and no read access to the statistics views the queries use. Without `pg_use_reserved_connections` monitoring stops when the application has used up `max_connections`; without the setting a monitoring query is not bounded to 5 s | `packs/postgresql/monitoring-role.sql` lines 12-14 (role and password), 16-17 (`pg_monitor`: read-only access to the statistics views and functions), 18-23 (reserved connection slots; the role does not exist on 15), 24-25 (5 s) |
| A `pg_hba.conf` entry that lets `otel_monitor` connect from the Collector's address, and a `listen_addresses` that includes the interface the Collector reaches | Required, unless an existing rule and listen address already admit it | The server refuses the connection. The test changes neither: the stock `postgres` image appends `host all all all <password_encryption>` to `pg_hba.conf` on first start and sets `listen_addresses = '*'` | PostgreSQL 18 docs: [auth-pg-hba-conf](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html) (`host` records match TCP/IP connections; remote connections need `listen_addresses`) and [runtime-config-connection](https://www.postgresql.org/docs/18/runtime-config-connection.html) (default `localhost`). Image: `postgres:18.7`, function `pg_setup_hba_conf` in `/usr/local/bin/docker-entrypoint.sh` and line 60 of `/usr/share/postgresql/18/postgresql.conf.sample` (read 2026-11-26) |
| `pg_stat_statements` in `shared_preload_libraries` (a server restart) and `CREATE EXTENSION pg_stat_statements` in database `postgres` | Optional | The `postgresql.statement.*` metrics (`execution_time`, `call`, `temp_block_written`, `deallocation`) are not emitted: the statement query returns no rows, without an error | `packs/postgresql/queries.yaml` lines 266-314 (comment: guard and why), 325-332 (guard), 337-340 (metrics); `packs/postgresql/otelcol.yaml` line 34 (the database the query list connects to) |
| `log_destination` with `jsonlog` and `logging_collector` on, and the Collector's read access to those files, with `OBENHUB_PG_LOG_GLOB` set to them | Optional | No PostgreSQL log signals: the glob matches nothing, as in the test. Metrics are not affected | `packs/postgresql/otelcol.yaml` lines 69-93 (file reader of jsonlog, parser, `start_at: beginning`); `deploy/collector/obenhub.env.example` line 37 (default glob `/var/log/postgresql/postgresql-*.json`); PostgreSQL 18 docs, [runtime-config-logging](https://www.postgresql.org/docs/18/runtime-config-logging.html) (`jsonlog` needs `logging_collector`; the file name ends in `.json`) |
| Network: Collector to the PostgreSQL port (5432 by default), Collector to the gateway on 4318 with the client certificate `tls.sh` wrote | Required | No metrics reach the database or the backend. The gateway rejects a client without a certificate that the CA signed | `deploy/compose/otelcol-gateway.yaml` lines 19-25 (port 4318, `client_ca_file` makes the server require and verify a client certificate); `deploy/compose/tls.sh` lines 1-9 (what it writes; client certificate for every host Collector); `deploy/compose/compose.yaml` line 31 (published port, default bind `0.0.0.0`) |

## 3. The Collector

Next to the database, as a [host binary](vm.md) or as a
[container](container.md).

## 4. What you should see

Wait before you judge. The tests wait from the Collector's start for the
longest `for:` among the collector, host and postgresql rules plus a 120 s margin
that is an assumption of the tests (`settle_wait` in `deploy/test/lib.sh` reads
the rule files; the value is `settle_seconds` in each line of
`deploy/results/runs.jsonl`). Today that is 900 s, the `for: 15m` of
`PostgresAutovacuumBacklog` and `PostgresAutovacuumTableDisabled`
(`packs/postgresql/rules.yml`), so 1020 s; the install test's recorded line of
2026-11-20 shows 720 s because it ran before those rules existed. Right after the start the
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
   empty too, and so are the four "Statements" panels until
   `pg_stat_statements` is enabled (see "What changes on the database").
   (The script needs `jq` and `curl`. The test accepts the two replication
   slot panels; the statement panels are newer than its recorded run.)

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
