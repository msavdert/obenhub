# lab/k8s

A kind cluster (one control plane, three workers, cluster name `obenhub`)
running the CloudNativePG operator and one `Cluster` named `pg` in namespace
`obenhub`: three PostgreSQL 18 instances, one per worker (required pod
anti-affinity on `kubernetes.io/hostname`), 1Gi each on kind's default
StorageClass, database `app`. Collectors in the cluster push to a backend
Compose project on the box (`obenhub-k8s`).

Needs Docker, `kind` 0.33.0 (the release whose node image `versions.sh`
pins), `kubectl`, `helm`, `openssl`, and `fs.inotify.max_user_watches` >= 524288
and `max_user_instances` >= 512 ([kind known issues][kind-ki]); `up.sh` stops
without changing sysctls if they are lower.

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
  where pgha uses mutual TLS across VMs.
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
  CloudNativePG's server certificate names only the Services, so the pod
  address cannot be verified: `sql_query` uses `sslmode=verify-ca` against the
  cluster CA (ConfigMap `obenhub-pg-ca`, public certificate), the `postgresql`
  receiver has no such mode and uses TLS without verification.
  The CA is copied when `up.sh` runs; after CloudNativePG rotates it (90 days
  by default, per the audit; not observed here), `sql_query` fails until
  `up.sh` runs again.
- Alerts: vmalert loads `lab/packs/postgresql/rules.yml` unchanged,
  `lab/packs/cnpg/rules.yml` (`CNPGPrimaryChanged`, unit tests in
  `lab/packs/cnpg/tests/`, `mise run lab:cnpg:rules-test`) and
  `mon/vmalert/inventory.yml`, which lists the five Collectors (gateway,
  cluster, one agent per worker named by the node) for `CollectorAbsent`;
  unit tests in `mon/vmalert/tests/collectors.yml` (`mise run
  lab:k8s:rules-test`). There is no PostgreSQL target inventory (which agent
  collects a pod depends on scheduling) and no Kubernetes rules yet.
  Notifications go to VictoriaLogs through the stage 3 Alertmanager config, as
  in pgha.

## Fault scenarios

```sh
lab/k8s/scenarios/control.sh             # no fault, CONTROL_SECONDS (default 600)
lab/k8s/scenarios/switchover.sh          # planned switchover to a replica
lab/k8s/scenarios/primary-deleted.sh     # kubectl delete pod of the primary
lab/k8s/scenarios/fenced.sh              # fence a replica (cnpg.io/fencedInstances)
lab/k8s/scenarios/replica-cut.sh         # NetworkPolicy cuts a replica from the primary
lab/k8s/scenarios/slot-retaining-wal.sh  # the cut replica's slot retains bounded WAL
```

The machinery is `lab/scenarios/lib-core.sh`, shared with stage 3 and pgha;
`scenarios/lib.sh` is the adapter (Cluster status instead of Patroni). Each run appends one
line to `results/runs.jsonl`. A scenario refuses to start unless the Cluster
is healthy (3 ready instances, one primary, two streaming replicas) and the
load client acknowledges rows.

- Load client: Deployment `obenhub-load` (`load/load.yaml`, applied by
  `up.sh`), the operand image, about five inserts a second through `pg-rw`
  into `app.load_rows` as the `app` role, credentials from CloudNativePG's
  Secret `pg-app`. It logs each acknowledged id to `/work/acked` in its pod;
  the role-changing scenarios fail when one of those rows is not on the new
  primary.
- `switchover`: `kubectl cnpg promote` when the plugin is installed (it is not
  on this box), otherwise the same change made directly (`status.targetPrimary`
  on the Cluster, which the plugin sets, per its source at v1.30.1).
- `fenced`: the annotation `cnpg.io/fencedInstances` on the Cluster (the plugin
  is not installed). The fenced pod's exporter keeps serving
  `cnpg_collector_fencing_on`, which `CNPGInstanceFenced` reads; its pack
  series stop.
- `replica-cut`, `slot-retaining-wal`: a NetworkPolicy on the primary admits
  every source except the replica's pod IP (kindnet enforces it, probed
  2026-11-11), then the replica's walsender is terminated, because a policy
  does not end an established connection. `slot-retaining-wal` then writes a
  scratch table until the replica's slot retains 640 MiB. The Cluster sets
  `max_slot_wal_keep_size: 1GB` as the guard (it was unlimited, and the 1Gi
  claim is not enforced by local-path); the alert threshold is 512 MiB.
- Both role changes expect `CNPGPrimaryChanged` and record old and new
  primary, timelines, the longest gap between acknowledged writes, the
  acknowledged rows (from 60 s before the fault) kept and lost, and the
  Kubernetes events of the window under `extra`.

All versions are pinned in `versions.sh`, with the source of each. The kind
and Cluster manifests hold a `${...}` placeholder that `up.sh` fills from it.
The cluster name is `KIND_CLUSTER` in `versions.sh`; every kubectl call uses
the context `kind-<name>`.

## Checked on 2026-11-10

`up.sh` from nothing: kind v0.33.0, node `v1.36.4`, CloudNativePG 1.30.1,
operand `postgresql:18.6-system-trixie`. Result:

- pods `pg-1`, `pg-2`, `pg-3` on `obenhub-worker`, `-worker2`, `-worker3`
- Cluster `Cluster in healthy state`, primary `pg-1`, 3 ready instances
- `show server_version` returns `18.6`; `pg_stat_replication` on the primary
  lists `pg-2` and `pg-3` as `streaming`
- a row inserted with `psql -h pg-rw` inside `pg-3` was served by the
  primary's pod IP with `pg_is_in_recovery()` false, and `pg-3` (in
  recovery) then read it back
- a second `up.sh` changes nothing and returns in about 2 seconds

## Collectors checked on 2026-11-10

`up.sh` from nothing took 6m28s: cluster ready after 245 s, backend 125 s
(most of it Grafana's plugin download and `--wait`), Secret, ConfigMaps and
both Helm releases 18 s. Chart `opentelemetry-collector` 0.178.3, image
`otel/opentelemetry-collector-contrib` 0.164.0. A second run changes nothing
(both releases `unchanged`, 6 s). Then, in VictoriaMetrics and VictoriaLogs:

- `postgresql.collection.heartbeat` and the other pack series exist for
  `pg-1`, `pg-2` and `pg-3`, with `k8s.pod.name`, `k8s.node.name` and
  `k8s.pod.uid`; `kubeletstats` (`k8s.pod.cpu.usage` on all three workers) and
  `k8s_cluster` (`k8s.node.condition_ready`, `k8s.deployment.available`) series
  are present; `otelcol_process_uptime` exists for the gateway, the cluster
  Collector and the three agents
- `select 1/0` on `pg-1` arrives as one log record with `error_severity`
  `ERROR`, `sql_state_code` `22012`, `user_name`, `database_name`,
  `backend_type`, `process_id` and the message `division by zero` as the body
- Kubernetes events arrive as log records (scaling `otelcol-cluster` to 2 and
  back gave `ScalingReplicaSet`, `Scheduled`, `Started`, `Killing`). The
  `k8sobjects` receiver in `watch` mode emitted none for events that happened
  before it started. The event body is a map without a message field, so
  VictoriaLogs shows its `_msg` placeholder; the text is in `object.note`
- vmalert, ten quiet minutes: only `Watchdog`. Keeping the agent off
  `obenhub-worker2` with a node affinity patch raised `CollectorAbsent` for
  `otelcol-agent-obenhub-worker2` alone (active 2 minutes after the patch,
  firing when read at 5m45s); removing the patch cleared it. On a fresh backend `CollectorAbsent` fires for the
  Collectors that are not yet installed, then clears once they push

## CloudNativePG exporter checked on 2026-11-10

On the running lab (Cluster created before `disableDefaultQueries` was set):

- before the change, `pg-1:9187/metrics` served 58 `cnpg_pg_*`, 3
  `cnpg_backends_*` and 20 `cnpg_collector_*` metric names, plus the Go
  runtime series
- `up.sh` set `disableDefaultQueries: true`, but the Cluster kept the
  `customQueriesConfigMap: cnpg-default-monitoring` entry that the defaulting
  webhook had added at creation, and the exporter kept serving `cnpg_pg_*`.
  Removing that entry (`kubectl patch --type=json`, op `remove`) stopped
  them, with no pod restart. A server-side dry run of
  `cnpg/cluster.yaml` as a new Cluster gets no such entry, so `up.sh` from
  nothing needs no patch; a lab created before this change needs it once
  (the `keep` filter would hide the duplicate queries in VictoriaMetrics)
- in VictoriaMetrics, `service.name=cnpg-instance-manager` holds the 17
  `cnpg_collector_*` names left after the drop, `cnpg_last_error` and the
  receiver's own `up` and `scrape_*`, for `pg-1`, `pg-2` and `pg-3`;
  no `cnpg_pg_*`, `cnpg_cache_*` or `go_*`

Not checked: a run on a cluster other than this one, and recovery after a
restart of the gateway container while the Collectors are running.

[kind-ki]: https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
