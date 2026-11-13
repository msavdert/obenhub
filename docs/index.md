# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, Oracle later.

## Status

Four labs run PostgreSQL topologies (Compose, Patroni on Compose and on VMs,
CloudNativePG on kind) with fault scenarios and alerting. The list of labs and
their evidence is in
[lab/README.md](https://github.com/msavdert/obenhub/blob/main/lab/README.md).
Pages on this site are added as the work behind them is done; the kinds of
page are described in
[CONTRIBUTING.md](https://github.com/msavdert/obenhub/blob/main/CONTRIBUTING.md).

## Start here

- [Decisions](adr/README.md): the ADRs.
- Reference: the [PostgreSQL pack](reference/postgresql-pack-metrics.md) and [Oracle Data Guard pack](reference/oracledb-dg-pack-metrics.md) metrics.
- [Roadmap](roadmap.md): what is planned, and in what order.
- [Changelog](changelog.md): released changes.
