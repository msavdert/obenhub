# Collector pack runbook

One section for each alert of `packs/collector/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/collector-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## CollectorAbsent

An expected Collector has sent no self-metrics (`otelcol_process_uptime`) for 2 minutes, so nothing it collects is seen. Reference: [CollectorAbsent](../reference/collector-pack-alerts.md#collectorabsent).

Look first: omitted; this repository has no query or script that reads the state of a Collector that has stopped reporting.

Seen in the lab:

- k8s: `worker-stopped` (suite `k8s-20261118T194429Z-37e22f2`)
- slice1: `collector-stopped` (suite `slice1-20261118T134118Z-37e22f2`)
