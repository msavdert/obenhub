# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, then Oracle.

## Status

Five labs run fault scenarios and alerting: four PostgreSQL topologies
(Compose, Patroni on Compose and on VMs, CloudNativePG on kind) and one Oracle
Data Guard pair on VMs. The list of labs and
their evidence is in
[lab/README.md](https://github.com/msavdert/obenhub/blob/main/lab/README.md).
Pages on this site are added as the work behind them is done; the kinds of
page are described in
[CONTRIBUTING.md](https://github.com/msavdert/obenhub/blob/main/CONTRIBUTING.md).

## Start here

- Guides: the [quick start](guides/quick-start.md), from a fresh Debian host to a fired and resolved alert on the slice1 lab, and the [install guide](guides/install.md) for your own PostgreSQL.
- [Decisions](adr/README.md): the ADRs.
- Reference: the [PostgreSQL pack](reference/postgresql-pack-metrics.md), [PgBouncer pack](reference/pgbouncer-pack-metrics.md), [Oracle Data Guard pack](reference/oracledb-dg-pack-metrics.md) and [Oracle RMAN backup pack](reference/oracledb-backup-pack-metrics.md) metrics.
- [Roadmap](roadmap.md): what is planned, and in what order.
- [Changelog](changelog.md): released changes.
