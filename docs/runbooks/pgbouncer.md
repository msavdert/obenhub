# PgBouncer pack runbook

One section for each alert of `packs/pgbouncer/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/pgbouncer-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

The `psql` console commands below run inside the PgBouncer container, with the monitoring password on stdin so it stays out of the argument list: `pgb_console()` in `lab/slice1/scenarios/lib.sh`.

## PgbouncerTargetAbsent

The Collector is alive but an expected PgBouncer target has sent no heartbeat for 2 minutes. Reference: [PgbouncerTargetAbsent](../reference/pgbouncer-pack-alerts.md#pgbouncertargetabsent).

Look first: Ask the console.

```bash
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW LISTS'
```

`SHOW LISTS` is the heartbeat (`packs/pgbouncer/queries.yaml`: any answer proves the console is up).

Seen in the lab:

- slice1: `pgbouncer-stopped` (suite `slice1-20261118T134118Z-37e22f2`)

## PgbouncerClientsWaiting

A client has waited over its limit (10 s unless the lab sets `obenhub.pgbouncer.oldest_wait_age.limit`) for a server connection: the pool is at `pool_size` with clients queued. Reference: [PgbouncerClientsWaiting](../reference/pgbouncer-pack-alerts.md#pgbouncerclientswaiting).

Look first: On the PgBouncer console.

```bash
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW POOLS'
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW DATABASES'
```

Query behind the metric: `packs/pgbouncer/queries.yaml`. Read `cl_waiting` and `maxwait` of the database named in the alert, and `pool_size`.

Seen in the lab:

- slice1: `pgbouncer-pool-saturated` (suite `slice1-20261118T134118Z-37e22f2`)

## PgbouncerPoolSaturated

The pool of a database has had 90 % or more of its `pool_size` linked to clients on average over 5 minutes; no client waits yet. Reference: [PgbouncerPoolSaturated](../reference/pgbouncer-pack-alerts.md#pgbouncerpoolsaturated).

Look first: On the PgBouncer console.

```bash
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW POOLS'
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW DATABASES'
```

Query behind the metric: `packs/pgbouncer/queries.yaml`. Compare `sv_active` with `pool_size`.

Seen in the lab:

- slice1: `pgbouncer-pool-saturated`, `pgbouncer-queueing` (suite `slice1-20261118T134118Z-37e22f2`)

## PgbouncerClientSaturation

Client connections are above 85 % of `max_client_conn` (critical at 95 %, when further clients are refused). Reference: [PgbouncerClientSaturation](../reference/pgbouncer-pack-alerts.md#pgbouncerclientsaturation).

Look first: On the PgBouncer console.

```bash
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW LISTS'
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW CONFIG'
```

Query behind the metric: `packs/pgbouncer/queries.yaml`. Read the `used_clients` row of `SHOW LISTS` and the `max_client_conn` row of `SHOW CONFIG`.

Seen in the lab:

- slice1: `pgbouncer-client-limit` (suite `slice1-20261118T134118Z-37e22f2`)

## PgbouncerWaitTime

Clients wait more than 0.1 seconds on average for a server assignment over 5 minutes, below the oldest wait limit of `PgbouncerClientsWaiting`. Reference: [PgbouncerWaitTime](../reference/pgbouncer-pack-alerts.md#pgbouncerwaittime).

Look first: On the PgBouncer console.

```bash
psql -h 127.0.0.1 -p 6432 -U otel_monitor -X -A -d pgbouncer -c 'SHOW STATS'
```

Query behind the metric: `packs/pgbouncer/queries.yaml`. `total_wait_time` over `total_server_assignment_count` is the average the alert reads; times are in microseconds (comment in `packs/pgbouncer/queries.yaml`).

Seen in the lab:

- slice1: `pgbouncer-queueing` (suite `slice1-20261118T134118Z-37e22f2`)
