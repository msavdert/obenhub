# lab/oracle

The Oracle lab of [ADR 0008](../../docs/adr/0008-oracle-lab-scope.md). What
runs so far is the database side of the first slice, the `CDB19` Data Guard
pair, and its Collector configuration. There are no scenarios, backend or
evidence yet, so the lab is not in the [lab table](../README.md).

## Prerequisites

The databases are not built from this repository (ADR 0008, Consequences).
The scripts expect, as `pair.sh` names them:

- ssh aliases `ora-au-lab`, `ora-dg-stby`, `ora-dg-obs` from this box, a user
  with passwordless sudo, the `oracle` OS user owning the Oracle homes;
- `CDB19` (19.33, open, primary) on `ora-au-lab` and `CDB19_STBY` (mounted,
  physical standby) on `ora-dg-stby`, one broker configuration with
  fast-start failover, SIDs listed in `/etc/oratab`, the listeners on port
  1521 under the `lab.local` names;
- a 19c Oracle home on `ora-dg-obs` (the observers'), used to check logins.

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
arrived. It is not installed on `ora-dg-obs` yet.
