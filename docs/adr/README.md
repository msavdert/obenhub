# Architecture decision records

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-goal-and-scope.md) | Goal and scope | Accepted |
| [0002](0002-otel-centred-architecture.md) | OpenTelemetry-centred architecture and reference backend | Accepted; decision 2 refined by ADR 0005 |
| [0003](0003-receiver-strategy.md) | Receiver strategy - engine receivers, SQL query packs, upstream | Accepted; scraped endpoints and the pack layout refined by ADR 0005 |
| [0004](0004-licence-policy.md) | Licence policy | Accepted |
| [0005](0005-lab-collection-topology-and-packs.md) | Collector topology, scraped endpoints, packs and MetricsQL | Accepted |
| [0006](0006-naming-contract.md) | Naming contract for metrics, attributes and alerts | Accepted |
| [0007](0007-backup-tool.md) | Backup tool - pgBackRest, compared with pg_basebackup | Accepted |

## Template

Copy to `NNNN-short-title.md` with the next free number, and add a row above.

```markdown
# ADR NNNN: Title

- Status: Proposed | Accepted | Superseded by ADR NNNN
- Date: YYYY-MM-DD

## Context

## Decision

## Consequences
```
