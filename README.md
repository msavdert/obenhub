# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, Oracle next.

Four labs run PostgreSQL topologies with fault scenarios and alerting; see
[lab/README.md](lab/README.md) for what runs and where its evidence is. The
decisions are in [docs/adr](docs/adr):

- [0001 Goal and scope](docs/adr/0001-goal-and-scope.md)
- [0002 OpenTelemetry-centred architecture and reference backend](docs/adr/0002-otel-centred-architecture.md)
- [0003 Receiver strategy](docs/adr/0003-receiver-strategy.md)
- [0004 Licence policy](docs/adr/0004-licence-policy.md)
- [0005 Collector topology, scraped endpoints, packs and MetricsQL](docs/adr/0005-lab-collection-topology-and-packs.md)
- [0006 Naming contract for metrics, attributes and alerts](docs/adr/0006-naming-contract.md)

## Development

```sh
mise install
mise run check
```

See [CONTRIBUTING.md](CONTRIBUTING.md).
