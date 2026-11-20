# CloudNativePG pack

`rules.yml` and `tests/` are the alerts; `dashboards/cnpg.json` is the dashboard, mounted by k8s.

## Collection interval

`CNPGPrimaryChanged` reads `postgresql.recovery.active`, which the labs
collect every 15 s: its `[1m]` window holds four collections and the `[3m]`
window twelve, at least two as the rule requires. At 60 s the `[1m]` window
holds one; the interval check is `PostgresCollectionIntervalTooLong`
(`packs/postgresql`), which reads its heartbeat from the same queries file.
