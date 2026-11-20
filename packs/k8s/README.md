# Kubernetes pack

`rules.yml` and `tests/` are the alerts on kubelet and cluster object state.

## Collector fragment

`otelcol.yaml` is the Collector fragment of this pack: receivers, processors and the pipelines named `*/obenhub-k8s*`, exporting to `otlp/obenhub`. It needs the base in [`../otelcol-base.yaml`](../otelcol-base.yaml) (exporter and extensions) and the files of this pack at `/etc/otelcol-contrib/packs/k8s/`. The lab Collector configurations stay hand-written; `mise run lint:otelcol` validates the fragment and fails when a lab block differs from it in more than endpoints, credentials, TLS and identity ([ADR 0005](../../docs/adr/0005-lab-collection-topology-and-packs.md) decision 3).

The kubeletstats and k8s_cluster values other than the kubelet verification are the chart presets and are unverified assumptions (see the comment in the fragment).

Variables:

| Variable | Meaning | Example |
| --- | --- | --- |
| `OBENHUB_K8S_KUBELET_INSECURE` | true skips verification of the kubelet certificate (a local kind cluster only) | `false` |
| `OBENHUB_K8S_NODE_NAME` | name of the node the Collector runs on (downward API spec.nodeName) |  |
