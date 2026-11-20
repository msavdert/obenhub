# Kubernetes pack runbook

One section for each alert of `packs/k8s/rules.yml` that a lab scenario fires; the other alerts are only in the [generated reference](../reference/k8s-pack-alerts.md). Each section gives what the alert means, the query or command to run first with the file it comes from, and the scenarios that fire it (scripts in `lab/<lab>/scenarios/`) with the latest passing run, named by its `suite` field in `lab/<lab>/results/runs.jsonl`.

## KubernetesNodeNotReady

The Ready condition of a node is not True for a minute. Reference: [KubernetesNodeNotReady](../reference/k8s-pack-alerts.md#kubernetesnodenotready).

Look first: The node's Ready condition.

```bash
kubectl get node <node> -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

`node_ready` in `lab/k8s/scenarios/worker-stopped.sh`.

Look first: Node events.

```logsql
object.reason:* object.regarding.kind:=Node _time:>$T_START | stats by (object.regarding.name, object.reason, object.type) count() n, min(_time) first | sort by (first)
```

Same file, `node_events`; the fields come from the k8sobjects receiver; run through the VictoriaLogs query endpoint `/select/logsql/query`, as `vl` in `lab/scenarios/lib-core.sh`.

Seen in the lab:

- k8s: `worker-stopped` (suite `k8s-20261118T194429Z-37e22f2`)
