# lab/oracle

The Oracle lab of [ADR 0008](../../docs/adr/0008-oracle-lab-scope.md). What
runs so far is the database side of the first slice, the `CDB19` Data Guard
pair, its Collector configuration and the backend the Collector pushes to.
There are no scenarios or evidence yet, so the lab is not in the
[lab table](../README.md).

## Prerequisites

The databases are not built from this repository (ADR 0008, Consequences).
The scripts expect, as `pair.sh` names them:

- ssh aliases `ora-au-lab`, `ora-dg-stby`, `ora-dg-obs` from this box, a user
  with passwordless sudo, the `oracle` OS user owning the Oracle homes;
- `CDB19` (19.33, open, primary) on `ora-au-lab` and `CDB19_STBY` (mounted,
  physical standby) on `ora-dg-stby`, one broker configuration with
  fast-start failover, SIDs listed in `/etc/oratab`, the listeners on port
  1521 under the `lab.local` names;
- a 19c Oracle home on `ora-dg-obs` (the observers'), used to check logins;
- Docker on this box for the backend, and `ora-dg-obs` able to reach this box
  at `10.0.0.11` (assumption: the lab LAN address; `gateway.sh` holds it).

## Provision

`scripts/provision.sh` creates the monitoring profile and the two common
users on the primary (ADR 0008 decision 4), copies the primary's password
file to the standby when the two differ, and checks every login from
`ora-dg-obs`. It creates `.env` (gitignored) with the passwords on first use.
A rerun creates nothing new and keeps the passwords (it states the profile
limits and grants again); `--reset-passwords` sets the passwords from `.env`
again.

## Collector

`files/otelcol-obs.yaml` is the configuration for the Collector on
`ora-dg-obs`: the `oracledb` receiver on the primary and the
[oracledb-dg pack](../packs/oracledb-dg) on both databases. It needs
`ORA_MON_PASSWORD` and `ORA_DG_PASSWORD` (the first 30 characters of the
`.env` values), `OBENHUB_GATEWAY_ENDPOINT` and client certificates under
`/etc/otelcol-contrib/tls`. On 2026-11-13 it ran in the
`otel/opentelemetry-collector-contrib:0.164.0` container on this box with
the exporter replaced by `debug` and `file`: the receiver's 25 default
metrics from `CDB19` and every pack metric that applies to each role (lag,
apply and gap from the standby, the redo destination from the primary)
arrived.

```sh
mise run lab:oracle:collector   # scripts/collector.sh, from this box over ssh
```

The script installs the otelcol-contrib `.rpm` of `OTELCOL_VERSION`
(`lab/pgha/versions.sh`, the pin all labs share) from the
opentelemetry-collector-releases release after checking its `.sha256` file,
then writes the configuration, the `oracledb-dg` pack's `queries.yaml`, the
client certificate from `pki/` and a root-only environment file
(`/etc/otelcol-contrib/obenhub.env`, read by systemd through a drop-in) with
the two passwords and the gateway endpoint. It restarts the service only when
the package or a file changed and fails unless the service stays active. It
needs `.env` (from `provision.sh`) and `pki/` (from `lab:oracle:mon:up` or
`lab:oracle:pki`). On 2026-11-13 the first run installed 0.164.0 on
`ora-dg-obs` (Oracle Linux 9.8) and started it; a second run changed nothing
and did not restart it. After three minutes the journal showed only the two
`CDB_PROCEDURES` fallback warnings the receiver logs at start, and
VictoriaMetrics held `oracledb.*` series from `CDB19` and `CDB19_STBY` whose
first samples are the Collector's first scrape.

## Backend

`mon/compose.yaml` runs on this box: a gateway Collector with a mutual-TLS
OTLP/HTTP receiver (the config is shared with [pgha](../pgha), at
`lab/mon/otelcol-gateway-mtls.yaml`), and the shared VictoriaMetrics,
VictoriaLogs, vmalert, Alertmanager and Grafana services of
[lab/mon](../mon). There are no alert rules or dashboards yet, so vmalert
loads an empty `inventory.yml`.

```sh
mise run lab:oracle:pki      # CA, gateway certificate, client certificate (lab/oracle/pki, gitignored)
mise run lab:oracle:mon:up   # writes mon/.env, then docker compose up --wait
mise run lab:oracle:mon:down # also deletes the volumes
```

`pki.sh` issues only what is missing and runs on every `mon:up`. After a
change of `GATEWAY_IP` in `gateway.sh`, delete `pki/gateway/` so the
gateway certificate is issued again with the new address.

Only the gateway listens on the LAN, the rest on `127.0.0.1`:

| Service | Host port |
| --- | --- |
| gateway (OTLP/HTTP, mutual TLS) | `10.0.0.11:54318` |
| VictoriaMetrics | 58428 |
| VictoriaLogs | 59428 |
| vmalert | 58880 |
| Alertmanager | 59093 |
| Grafana | 53000 |

The gateway certificate has `10.0.0.11` as its SAN. `ca.crt`, `otelcol.crt` and
`otelcol.key` from `pki/` go to `/etc/otelcol-contrib/tls` on `ora-dg-obs`
(`OBENHUB_GATEWAY_ENDPOINT=https://10.0.0.11:54318`). On 2026-11-13 the
Collector configuration above ran in the contrib 0.164.0 container on this box
against this backend with the client certificate: 38 `oracledb.*` metric names
reached VictoriaMetrics, 34 for `CDB19` and 11 for `CDB19_STBY` (both pack
roles). A client without a certificate was refused (curl exit 56).
