# Patroni pack

`rules.yml` and `tests/` are the alerts; `dashboards/patroni.json` is the dashboard, mounted by stage3 and pgha.

## Collection interval

The rules assume the Patroni `/metrics` scrape every 15 s (`prometheus`
receiver `scrape_interval: 15s` in the labs). A window holds at least two
collections: `[30s]` in `PatroniMultiplePrimaries`, and `[1m]` on
`postgresql.collection.heartbeat` (the `postgresql` pack's 15 s source) and
on `otelcol_process_uptime` in `PatroniTargetAbsent`.
`PatroniCollectionIntervalTooLong` fires when the samples of `up` of the
Patroni scrape are on average more than 20 s apart.
