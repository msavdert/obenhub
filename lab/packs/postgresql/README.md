# PostgreSQL pack

`queries.yaml` is the `sql_query` list every PostgreSQL target of the labs
shares; `rules.yml` and `tests/` are its alerts. The metric list is generated:
[docs/reference/postgresql-pack-metrics.md](../../../docs/reference/postgresql-pack-metrics.md).
Names follow [ADR 0006](../../../docs/adr/0006-naming-contract.md).

## PostgreSQL version

The pack needs PostgreSQL 18 and is tested on 18 only. One query needs it:
the conflict counters query reads `confl_insert_exists` and six more `confl_*`
columns of `pg_stat_subscription_stats`, which the PostgreSQL 17 documentation
does not list and the 18 documentation does (both read 2026-11-11). On 17 or
older that query fails and only `postgresql.subscription.conflict` is lost;
each query runs on its own, so the others still report.

The remaining queries use columns from older releases. These versions are
from memory and not checked against the documentation (unverified):

- `reserved_connections` setting: 16.
- `pg_stat_subscription.worker_type`: 16.
- `pg_replication_slots.inactive_since` and `invalidation_reason`: 17.
- `pg_locks.waitstart`, `pg_get_wal_replay_pause_state()`: 14.
- `pg_stat_subscription_stats` itself: 15.

So the pack as a whole would need 18; the other queries alone would need 17.

## Checks

`scripts/check-pack-names.py` (part of `mise run check`) fails when a pack
metric has no unit, ends in a unit word, has an undotted attribute, or has the
name of a postgresqlreceiver metric (`upstream-receiver-metrics.txt`).
