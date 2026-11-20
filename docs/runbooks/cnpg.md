# CloudNativePG pack runbook

One section for each alert of `packs/cnpg/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/cnpg-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## CNPGPrimaryChanged

A member that is now writable was in recovery within the last 3 minutes: a replica was promoted, by switchover or failover. Reference: [CNPGPrimaryChanged](../reference/cnpg-pack-alerts.md#cnpgprimarychanged).

Look first: Kubernetes events of the cluster's namespace.

```logsql
object.reason:* object.regarding.namespace:=<namespace> _time:>$T_START | stats by (object.regarding.kind, object.regarding.name, object.reason, object.type) count() n, min(_time) first | sort by (first)
```

`event_reasons` in `lab/k8s/scenarios/lib.sh`; run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`. A planned switchover is `kubectl cnpg promote` (`promote_to`, same file).

Seen in the lab:

- k8s: `primary-deleted`, `switchover`, `worker-stopped` (suite `k8s-20261118T194429Z-37e22f2`)

## CNPGInstanceFenced

CloudNativePG reports the instance fenced for a minute: PostgreSQL is stopped in a pod that stays Running but not ready. Reference: [CNPGInstanceFenced](../reference/cnpg-pack-alerts.md#cnpginstancefenced).

Look first: Fencing annotation and pod readiness.

```bash
kubectl -n <namespace> get cluster <cluster> -o jsonpath='{.metadata.annotations}'
kubectl -n <namespace> get pod <pod> -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}'
```

The annotation key is `cnpg.io/fencedInstances` (`lab/k8s/scenarios/fenced.sh`, which also holds the pod readiness form); the Cluster `jsonpath` form is from `lab/k8s/scripts/up.sh`.

Seen in the lab:

- k8s: `fenced` (suite `k8s-20261118T194429Z-37e22f2`)
