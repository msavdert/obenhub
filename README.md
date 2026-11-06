# obenhub

obenhub (OBservability ENgineering hub) is a learning platform for
OpenTelemetry-centred database and operating-system monitoring, fully open
source under Apache 2.0. PostgreSQL first, Oracle next.

Nothing runs yet. The decisions so far are in [docs/adr](docs/adr):

- [0001 Goal and scope](docs/adr/0001-goal-and-scope.md)
- [0002 OpenTelemetry-centred architecture and reference backend](docs/adr/0002-otel-centred-architecture.md)
- [0003 Receiver strategy](docs/adr/0003-receiver-strategy.md)
- [0004 Licence policy](docs/adr/0004-licence-policy.md)

## Development

```sh
mise install
mise run check
```

See [CONTRIBUTING.md](CONTRIBUTING.md).
