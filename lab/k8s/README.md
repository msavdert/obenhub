# lab/k8s

A kind cluster (one control plane, three workers, cluster name `obenhub`)
running the CloudNativePG operator and one `Cluster` named `pg` in namespace
`obenhub`: three PostgreSQL 18 instances, one per worker (required pod
anti-affinity on `kubernetes.io/hostname`), 1Gi each on kind's default
StorageClass, database `app`. Collectors in the cluster push to a backend
Compose project on the box (`obenhub-k8s`).

## Prerequisites

- Docker, with access to the internet (images, the CloudNativePG manifest, the
  Helm chart repository).
- `curl`, `jq`, `sha256sum`, `openssl`.
- Linux x86_64 only (the `kubectl-cnpg` asset pattern in `mise.k8s.toml`).
- The tools pinned in [`mise.k8s.toml`](../../mise.k8s.toml), read only with
  `MISE_ENV=k8s` so that CI and `mise run check` do not download them (about
  235 MB): `kind` 0.33.0 (the release whose node image `versions.sh` pins),
  `kubectl` 1.36.6 (within one minor of the node image's Kubernetes 1.36),
  `helm` 4.3.1 and the `kubectl-cnpg` plugin 1.30.1 (the scenarios call
  `kubectl cnpg promote`). `MISE_ENV=k8s mise install` fetches them.
  `scripts/check-tools.sh` compares each exactly with its pin, checks the
  kubectl skew and that the plugin pin equals `CNPG_VERSION`; `up.sh` runs it
  first and, when the tools are not on PATH, re-runs itself once under
  `MISE_ENV=k8s mise exec --`, as do the scenarios. `mise run
  lab:k8s:scenarios` sets the environment itself.
- `fs.inotify.max_user_watches` >= 524288 and `max_user_instances` >= 512
  ([kind known issues][kind-ki]); `up.sh` stops without changing sysctls if
  they are lower.
- Free ports on 127.0.0.1 (VictoriaMetrics 48428, VictoriaLogs 49428, vmalert
  48880, Alertmanager 49093, Grafana 43000) and 44317 on the `kind` network's
  gateway address (see Monitoring).
- The backend services extend `lab/mon/compose.base.yaml`; the Alertmanager
  config and Grafana provisioning are the shared ones in `lab/mon/`.

```sh
lab/k8s/scripts/up.sh     # idempotent; about 7 minutes from nothing
lab/k8s/scripts/down.sh   # deletes the kind cluster, the backend and all data
```

## Monitoring

```text
kind cluster                                   box (Compose project obenhub-k8s)
  agent DaemonSet (3, one per worker)  --+
    kubeletstats, container logs,        |  OTLP/HTTP, plain
    PostgreSQL pack per CNPG pod,        |
    CNPG exporter (cnpg_collector_*)     +-> gateway Collector -> VictoriaMetrics, VictoriaLogs
  cluster Deployment (1)               --+   (172.16.9.1:44317)    vmalert -> Alertmanager, Grafana
    k8s_cluster, Kubernetes events
```

- Backend (`mon/`): the images and flags of `lab/pgha/mon`. Ports on
  127.0.0.1: VictoriaMetrics 48428, VictoriaLogs 49428, vmalert 48880,
  Alertmanager 49093, Grafana 43000. The gateway listens on the IPv4 gateway
  of the `kind` Docker network (`172.16.9.1` on the last run), port 44317,
  which `up.sh` reads with `docker network inspect` into `mon/.env`
  (gitignored). The traffic stays on this box's bridge, so it is plain OTLP/HTTP
  where pgha uses mutual TLS across VMs. Grafana provisions
  `grafana/dashboards/cnpg.json` (CloudNativePG and Kubernetes: one panel per
  scenario alert, plus pod and node resources) and the shared PostgreSQL
  dashboard of slice 1 (its PgBouncer and logical-replication rows are empty
  here). `mise run lab:k8s:panels` runs both dashboards' queries against the
  live Grafana; panels marked "Data only during a scenario" are empty while the
  cluster is healthy.
- Collectors (`otel/`): the official `opentelemetry-collector` Helm chart,
  two releases in namespace `obenhub-otel`, image
  `otel/opentelemetry-collector-contrib` pinned by tag and digest in
  `versions.sh`. Presets: `kubernetesAttributes` (all pipelines),
  `kubeletMetrics`, `logsCollection` (agent), `clusterMetrics`,
  `kubernetesEvents` (cluster).
- PostgreSQL pack: `receiver_creator` with `k8s_observer` creates the
  `postgresql` receiver and the `sql_query` receiver with
  `lab/packs/postgresql/queries.yaml` (mounted from a ConfigMap) for every
  pod labelled `cnpg.io/cluster=pg` on the agent's own node. Series are named
  by pod (`service.instance.id`, `server.address` = `pg-1`...), never by role,
  and carry the `k8s.*` attributes.
- CloudNativePG's exporter (container port `metrics`, 9187, plain HTTP):
  the same `k8s_observer` starts a `prometheus` receiver per instance pod,
  which keeps `cnpg_collector_*` and `cnpg_last_error`: operator state
  (fencing, switchover required, replica mode, nodes used) and figures the
  pack does not collect (`pg_wal` directory, archive status, WAL generation,
  large-object pages) and drops the three backup timestamps the exporter marks
  Deprecated. The Cluster sets `monitoring.disableDefaultQueries`, so the
  exporter does not run its default queries, which repeat the pack.
  `service.name` is `cnpg-instance-manager`; `k8s_attributes` already names
  the operator pod `cloudnative-pg` after its `app.kubernetes.io/name` label.
- Container logs of CloudNativePG are JSON; the agent parses the line and, for
  `logger=postgres`, turns every field of `record` (`error_severity`,
  `sql_state_code`, `query`, ...) into a flat attribute, as pgha does, and the
  record message into the body. Every line of an instance's `postgres`
  container, the instance manager's included (`logger` tells them apart),
  carries the metrics' identity (`service.instance.id` = pod). The
  Collectors' own logs are excluded.
- Role: a CloudNativePG managed role `otel_monitor` (`pg_monitor`,
  `pg_use_reserved_connections`) with a random password in the Secret
  `pg-otel-monitor`, which `up.sh` creates once and copies to `obenhub-otel`.
  The pod address is probably not in the server certificate (unverified; the
  [CloudNativePG 1.30 certificates page](https://cloudnative-pg.io/docs/1.30/certificates)
  does not list the generated names), so `sql_query` uses `sslmode=verify-ca` against the
  cluster CA (ConfigMap `obenhub-pg-ca`, public certificate), the `postgresql`
  receiver has no such mode and uses TLS without verification.
  The CA is copied when `up.sh` runs; after CloudNativePG renews it (90-day validity of generated certificates, renewed
  7 days before expiry, per the same page; the CA's own period and any
  rotation here are unverified), `sql_query` fails until
  `up.sh` runs again.
- Alerts: vmalert loads `lab/packs/collector/rules.yml` and `lab/packs/postgresql/rules.yml` unchanged,
  `lab/packs/cnpg/rules.yml` (`CNPGPrimaryChanged`, unit tests in
  `lab/packs/cnpg/tests/`, `mise run lab:cnpg:rules-test`),
  `lab/packs/k8s/rules.yml` (`KubernetesNodeNotReady`, from the
  `k8s_cluster` receiver's `k8s.node.condition_ready`; `mise run
  lab:k8s-pack:rules-test`) and
  `mon/vmalert/inventory.yml`, which lists the five Collectors (gateway,
  cluster, one agent per worker named by the node) for `CollectorAbsent`;
  unit tests in `mon/vmalert/tests/collectors.yml` (`mise run
  lab:k8s:rules-test`). There is no PostgreSQL target inventory (which agent
  collects a pod depends on scheduling). `otelcol-cluster` is pinned to the
  control-plane node (`otel/cluster-values.yaml`), so stopping a worker does not
  take the node-condition signal with it.
  Notifications go to VictoriaLogs through the shared Alertmanager config
  (`lab/mon/alertmanager.yml`), as in pgha.

## Fault scenarios

```sh
lab/k8s/scenarios/control.sh             # no fault, CONTROL_SECONDS (default 600)
lab/k8s/scenarios/switchover.sh          # planned switchover to a replica
lab/k8s/scenarios/primary-deleted.sh     # kubectl delete pod of the primary
lab/k8s/scenarios/fenced.sh              # fence a replica (cnpg.io/fencedInstances)
lab/k8s/scenarios/replica-cut.sh         # NetworkPolicy cuts a replica from the primary
lab/k8s/scenarios/slot-retaining-wal.sh  # the cut replica's slot retains bounded WAL
lab/k8s/scenarios/worker-stopped.sh      # power cut of the primary's worker node
```

The machinery is `lab/scenarios/lib-core.sh`, shared with slice 1, stage 3 and pgha;
`scenarios/lib.sh` is the adapter (Cluster status instead of Patroni). Each run
appends one line to `results/runs.jsonl`. `mise run lab:k8s:scenarios` runs them
all as a suite, `control` last (see [lab/README.md](../README.md)). A scenario
refuses to start unless the Cluster is healthy (3 ready instances, one primary,
two streaming replicas) and the load
client acknowledges rows.

- Load client: Deployment `obenhub-load` (`load/load.yaml`, applied by
  `up.sh`), the operand image, about five inserts a second through `pg-rw`
  into `app.load_rows` as the `app` role, credentials from CloudNativePG's
  Secret `pg-app`. It logs each acknowledged id to `/work/acked` in its pod;
  the role-changing scenarios fail when one of those rows is not on the new
  primary.
- `switchover`: `kubectl cnpg promote` (the plugin pinned in `mise.k8s.toml`; it
  sets `status.targetPrimary` on the Cluster, per its source at v1.30.1, see
  `promote_to` in `scenarios/lib.sh`).
- `fenced`: the annotation `cnpg.io/fencedInstances` set directly on the
  Cluster. The fenced pod's exporter keeps serving
  `cnpg_collector_fencing_on`, which `CNPGInstanceFenced` reads; its pack
  series stop.
- `replica-cut`, `slot-retaining-wal`: a NetworkPolicy on the primary admits
  every source except the replica's pod IP (kindnet enforces it, probed
  2026-11-11), then the replica's walsender is terminated, because a policy
  does not end an established connection. `slot-retaining-wal` then writes a
  scratch table until the replica's slot retains 640 MiB. The Cluster sets
  `max_slot_wal_keep_size: 1GB` as the guard (it was unlimited; local-path does not
  enforce the volume size, per the comment in `cnpg/cluster.yaml`); the alert threshold is 512 MiB.
- `worker-stopped`: `docker kill` of the kind node that runs the
  primary (a worker free of the operator and the load client; a preparatory
  switchover if needed), held until `CollectorAbsent` for that node's agent
  fires (about 4 minutes down, below the pods' 300 s not-ready toleration), then
  `docker start`. Expects `CNPGPrimaryChanged`, `KubernetesNodeNotReady` and
  `CollectorAbsent`; the power cut is asynchronous-replication territory, so
  lost acknowledged rows are recorded (`writer_missing`) and fail the run only
  when one was acknowledged more than 10 s before the kill.
- Both role changes expect `CNPGPrimaryChanged` and record old and new
  primary, timelines, the longest gap between acknowledged writes, the
  acknowledged rows (from 60 s before the fault) kept and lost, and the
  Kubernetes events of the window under `extra`.

All versions are pinned in `versions.sh`, with the source of each. The kind
and Cluster manifests hold a `${...}` placeholder that `up.sh` fills from it.
The cluster name is `KIND_CLUSTER` in `versions.sh`; every kubectl call uses
the context `kind-<name>`.

## Behaviour worth knowing

Observed on 2026-11-10 while building the lab (versions in `versions.sh`; the
scenario runs are in `results/runs.jsonl`):

- `up.sh` is idempotent: a second run changes nothing.
- Kubernetes events arrive as log records, but the `k8sobjects` receiver in
  `watch` mode emitted none for events that happened before it started. The
  event body is a map without a message field, so VictoriaLogs shows its
  `_msg` placeholder; the text is in `object.note`.
- On a fresh backend `CollectorAbsent` fires for the Collectors that are not
  installed yet and clears once they push.
- The Cluster keeps `monitoring.disableDefaultQueries: true` from creation; the
  exporter then serves no `cnpg_pg_*`, `cnpg_cache_*` or `go_*` series, only
  `cnpg_collector_*`, `cnpg_last_error` and the receiver's own `up` and
  `scrape_*`.

Not checked: a run on a cluster other than this one, and recovery after a
restart of the gateway container while the Collectors are running.

[kind-ki]: https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
