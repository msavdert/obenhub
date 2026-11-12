# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, Oracle next.

## Status

Four labs run PostgreSQL topologies (Compose, Patroni on Compose and on VMs,
CloudNativePG on kind) with fault scenarios and alerting. The list of labs and
their evidence is in
[lab/README.md](https://github.com/msavdert/obenhub/blob/main/lab/README.md).
Pages on this site are added as the work behind them is done.

## How these docs are organised

Pages fall into four kinds. A section appears in the navigation only once it
has a real page.

- **Learn**: how OpenTelemetry and the database fit together.
- **Guides**: how to monitor a given topology, once it runs in the lab.
- **Reference**: metrics, events, attributes and configuration. Today one
  generated page, [PostgreSQL pack metrics](reference/postgresql-pack-metrics.md).
- **Decisions**: the ADRs.

## Start here

- [Decisions](adr/README.md): the ADRs.
- [Reference](reference/postgresql-pack-metrics.md): the PostgreSQL pack metrics.
- [Roadmap](roadmap.md): what is planned, and in what order.
- [Changelog](changelog.md): released changes.
