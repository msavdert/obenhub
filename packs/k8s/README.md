# Kubernetes pack

`rules.yml` and `tests/` are the alerts on kubelet and cluster object state.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-k8s*`, exporting to `otlp_http/obenhub`. It needs the base in [`../otelcol-base-k8s.yaml`](../otelcol-base-k8s.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/k8s/`. The lab Collector configurations stay hand-written. `mise run lint:otelcol` validates the fragment with its base (it does not start the Collector: the pod observer and the kubelet need a cluster), and fails when a lab block differs from it, except in hosts, ports, endpoints, targets, usernames and TLS settings, identity values, and the entries of `ALLOW` in `scripts/check-otelcol-fragments.py`, each with a reason; a lab credential must stay an `${env:...}` reference ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

The values are those of the `opentelemetry-collector` chart 0.178.3 presets (source and licence in the fragment). The service account needs the chart's ClusterRole rules for these presets (`templates/clusterrole.yaml`): get, list and watch on pods, namespaces, replicasets and the cluster-metrics resources, and get on `nodes/stats`.

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `K8S_NODE_IP` | IP of the node the pod runs on (the chart sets it from status.hostIP); the kubelet is read at port 10250 |  |
| `K8S_NODE_NAME` | name of the node the pod runs on (downward API spec.nodeName); filters k8s_attributes and, in the k8s base, the pod observer |  |
| `OBENHUB_K8S_KUBELET_INSECURE` | true skips verification of the kubelet certificate (a local kind cluster only) | `false` |
