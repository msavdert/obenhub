# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, then Oracle.

Five labs, four PostgreSQL topologies and one Oracle Data Guard pair, run
fault scenarios and alerting; see
[lab/README.md](lab/README.md) for what runs and where its evidence is. The
decisions are listed in [docs/adr/README.md](docs/adr/README.md), the plans
in [docs/roadmap.md](docs/roadmap.md).

## Development

```sh
mise install
mise run check
```

See [CONTRIBUTING.md](CONTRIBUTING.md).
