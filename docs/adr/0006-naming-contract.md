# ADR 0006: Naming contract for metrics, attributes and alerts

- Status: Accepted
- Date: 2026-11-11

## Context

ADR 0002 asks for a naming contract; it was to be written with the first
query pack and was not. Six packs exist (`lab/packs/`), and their names have
drifted: `replication_slot.inactive_seconds` and `retained_bytes` carry a unit,
`snapshot.oldest_age` and `replay.backlog` do not; `LogicalSlotRetainingWal`
and `ReplicationSlotRetainingWAL` differ in spelling; most PostgreSQL alerts
have no component prefix; and the resource attribute `db.cluster.name` is not
in the semantic conventions.

Sources read on 2026-11-11:

- Semantic conventions v1.45.0,
  [`docs/general/naming.md`](https://github.com/open-telemetry/semantic-conventions/blob/v1.45.0/docs/general/naming.md):
  attribute naming is Stable, metric naming is Development. Units are not
  part of metric names; namespaces are dot-separated, words within a
  component joined with `_`; `entity.limit`, `entity.usage`,
  `entity.utilization` and `entity.time` have fixed meanings; no rule covers
  elapsed-time gauges.
- Same version,
  [`model/db/registry.yaml`](https://github.com/open-telemetry/semantic-conventions/blob/v1.45.0/model/db/registry.yaml)
  and [`docs/db/postgresql.md`](https://github.com/open-telemetry/semantic-conventions/blob/v1.45.0/docs/db/postgresql.md):
  `db.system.name` is `postgresql`, `db.namespace` is `{database}|{schema}`;
  there is no `db.cluster.name` and no attribute for a database cluster, and
  no `postgresql.*` metric or attribute.
- Collector contrib v0.164.0,
  [`receiver/postgresqlreceiver/metadata.yaml`](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.164.0/receiver/postgresqlreceiver/metadata.yaml):
  metrics under `postgresql.*` (for example `postgresql.wal.age`, unit `s`),
  resource attribute `postgresql.database.name`, attribute
  `postgresql.conflict.type`.

## Decision

The contract covers names this project chooses. Names that arrive from
upstream (receiver metrics, Patroni, etcd and CloudNativePG `/metrics`,
Kubernetes attributes) are used as they arrive.

1. **Metric namespace.** Pack metrics for PostgreSQL use `postgresql.*`, the
   receiver's namespace, so that a pack metric can become a receiver metric
   (ADR 0003, layer 3) without a rename. A pack name never equals a name the
   receiver defines at the pinned contrib version; a check enforces it. Other
   engines and components follow the same pattern (`pgbouncer.*`).
2. **Metric names.** `<namespace>.<entity>.<measure>`, lowercase, dots between
   components, `_` inside a component, singular. No unit in the name; the
   `unit` field is always set (UCUM: `s`, `By`, `1`, or a `{annotation}`).
   - Elapsed time as a gauge: the last component ends in `age`, unit `s`
     (`postgresql.snapshot.oldest_age`, as the receiver's `postgresql.wal.age`).
     An age in transactions keeps `age` with unit `{transaction}`.
   - A 0/1 state: an adjective or participle, unit `1`
     (`postgresql.replication_slot.active`).
   - A current number of things: `.count`; a configured maximum: `.limit`.
   - A cumulative counter is a monotonic sum named for what it counts.
3. **Attributes.** Lowercase, dot-namespaced. Use a semantic-conventions or
   receiver attribute when one means the same thing
   (`postgresql.database.name`, `postgresql.conflict.type`). Otherwise
   `postgresql.<entity>.<property>` (`postgresql.replication_slot.name`).
   Never a bare column name (`datname`, `slot_name`).
4. **Project attributes.** Attributes that only this project defines live
   under `obenhub.*`: the inventory (`obenhub.expected_*`, `obenhub.collector`)
   and the cluster a target belongs to, `obenhub.cluster.name`, which replaces
   `db.cluster.name`. Members of one streaming cluster share it; a logical
   subscriber is its own cluster.
5. **Alert names.** `UpperCamelCase`, prefixed with the component
   (`Postgres`, `Pgbouncer`, `Patroni`, `Etcd`, `CNPG`, `Kubernetes`, `Host`,
   `Collector`), then the condition. Acronyms stay upper case (`WAL`, `CNPG`).
   Two alerts never describe the same condition.
6. **Generated reference.** The metric list of each pack is generated from its
   query file and checked in `mise run check`; it is not written by hand.

## Consequences

- Renaming is one change across queries, rules, unit tests, dashboards,
  scenarios and inventories, and every lab's evidence is retaken afterwards.
- A metric whose name is still changing is not described in prose outside its
  generated list.
- The contract is reviewed when semantic conventions declare metric naming
  stable or add PostgreSQL entries.
