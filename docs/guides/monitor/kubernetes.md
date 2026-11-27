# PostgreSQL on Kubernetes

The Collector runs as two releases of the upstream `opentelemetry-collector`
Helm chart: `agent`, a DaemonSet that reads the PostgreSQL pods of its node
(and the node's kubelet and container logs), and `cluster`, one replica for the
cluster-wide Kubernetes metrics and events. Both send to the backend of
[the guide's index](index.md). Do step 1 there first (the backend) and read
"What changes on the database". This page is written from
[`deploy/test/k8s-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/k8s-test.sh),
which follows it on a kind cluster of its own for two targets: a plain
StatefulSet running the stock `postgres` image, and a CloudNativePG Cluster.
Where the test differs from what you would run, the text says so.

## What the Kubernetes test proves, and what it does not

The latest runs are lines of `deploy/results/runs.jsonl` with `"test":
"k8s-sts-test"` and `"k8s-cnpg-test"`. Backend: this machine (Docker). Target:
a kind cluster of its own (one node, Kubernetes 1.36, kind 0.33.0), built by the
test and deleted by it; the Collector releases are chart 0.180.0 with the
Collector 0.165.0 image of the gateway.

**StatefulSet** (2026-11-27 11:53 UTC, commit 9e48300): passed in 1269 s against `postgres:18.7-trixie` with default
settings, no TLS and no `pg_stat_statements`, with `agent-values.yaml` only.
After a 1020 s settle the heartbeat of `pgdemo-0` was in VictoriaMetrics (1
series), nothing but `Watchdog` fired and nothing was pending, no alert but
`Watchdog` fired after the start (`CollectorAbsent` of the two Collectors is
tolerated for 120 s after their start, as in the other tests), the dead-man receiver got `Watchdog` six times 60 s
apart, no Collector container had restarted and the Collectors' logs held no line
with "error". The pod's `k8s.pod.phase` and `k8s.pod.cpu.time` series were in
VictoriaMetrics and 4 container log records of the pod in VictoriaLogs, one of
them the `division by zero` error of the test's own `SELECT 1/0`. 21
panels of the PostgreSQL dashboard had data, 18 are empty by design (four of them
the "Statements" panels, because the stock image does not preload
`pg_stat_statements`) and 2 replication slot panels are accepted empty because a
plain server has none. The host dashboard and the CloudNativePG one were not run
(the line lists them with the reason).

**CloudNativePG** (2026-11-27 12:39 UTC, commit e196fd3): passed in 1353 s
against operator 1.30.2 (manifest checksum verified) and a two-instance Cluster
`pgdemo` with default settings and TLS on, with `agent-values.yaml` and
`cnpg-values.yaml`. After the same 1020 s settle the heartbeat was in
VictoriaMetrics for both instances (2 series), nothing but `Watchdog` fired and
nothing was pending, no alert but `Watchdog` fired after the start (same 120 s
tolerance), the dead-man receiver got `Watchdog` five times 60 s apart, no
Collector container had restarted, `cnpg_collector_up` had one series per
instance, VictoriaLogs held 3 container log records of the primary (one the
`division by zero` of the test's `SELECT 1/0`) and 6 PostgreSQL records parsed
from the JSON logs (`service.name` `postgresql`, cluster `pgdemo`). 44 panels of
the PostgreSQL dashboard (for the primary) and the CloudNativePG dashboard had
data and 17 are empty by design, the list above less the server-log panel: the
Statements panels are empty here too (the test enables no
`pg_stat_statements`). The Collectors' logs held one line with "error" (the
count is recorded in the line as `collector_log_error_lines` and printed, not
asserted; what it said is not recorded). The host dashboard was not run.

What the test does not exercise: see "Limitations" below. The ones that matter
most: one node, no failover, no TLS to a StatefulSet's PostgreSQL, no
`pg_stat_statements` on either target, the host dashboard.

## What you need

- A Kubernetes cluster and `kubectl`, `helm` and `envsubst` on the
  machine you install from; a checkout of the repository (the values, the
  PostgreSQL pack's query files and `monitoring-role.sql` are files in it).
  The test uses kind v0.33.0 with the node image of `lab/k8s/versions.sh`
  (Kubernetes 1.36), `kubectl` 1.37 and helm 4.3.2 (`mise.k8s.toml`); other
  versions are untested.
- Pods that can reach the gateway: the machine that runs the backend, on port
  4318 of an address the pods route to. The test uses the address of the
  backend machine and passes it to `tls.sh` (below).
- PostgreSQL pods that the Collector can select by label, and that accept a
  TCP login of `otel_monitor` from the Collector's pod (`pg_hba.conf`; the
  stock image and CloudNativePG both do).
- Nodes whose kubelet the Collector can read: the agent runs as root to read
  the container logs under `/var/log/pods` and mounts a `hostPath` for its
  file offsets, so the namespace must allow that (no Pod Security `restricted`
  profile; assumption, not tested).

## 1. The backend, and what it must know about the cluster

Step 1 of the [index](index.md) with the address the pods use to reach the
gateway in the certificate, and a host port the pods can reach (the test binds
the gateway to that address only, `OBENHUB_GATEWAY_BIND`):

```sh
cd deploy/compose
bash tls.sh 192.0.2.10      # the address or DNS name of the backend machine as the pods see it
```

Then tell the inventory what to expect, before `docker compose up`. Pods have
generated names, so the entries are your pods' names: the Collector's
`service.instance.id` is `otelcol-agent-<node name>` for the agent of each node
and `otelcol-cluster` for the cluster release, and a database's is its pod
name. Edit `deploy/compose/inventory.yml` to this shape (the test writes the same
thing for its one node and its pods; `pgdemo-0` and `kind-control-plane` are
examples):

```yaml
      - record: obenhub.expected_collector
        expr: |
          union(
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-gateway"),
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-agent-kind-control-plane", "obenhub.upstream", "otelcol-gateway"),
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-cluster", "obenhub.upstream", "otelcol-gateway")
          )

      - record: obenhub.expected_target
        expr: |
          union(
            label_set(vector(1), "service.namespace", "obenhub", "service.name", "postgresql", "obenhub.cluster.name", "pgdemo", "service.instance.id", "pgdemo-0", "obenhub.collector", "otelcol-agent-kind-control-plane")
          )
```

Replace the example `pg-1` and `otelcol-host-1` entries of the file; the
inventory is the one place that lists what you run (its header says how).
`obenhub.cluster.name` is the name you give the pods' group in
`OBENHUB_CLUSTER_NAME` below. A pod that gets a new name (a StatefulSet keeps its
pod names; CloudNativePG names instances `<cluster>-<n>`, and a replaced
instance may get a new number: assumption, not tested) needs an edit and
`docker compose kill -s SIGHUP vmalert`.

The pod names exist only once the database runs, so the test creates the
database first, writes the inventory, then starts the backend and the Collectors
right after. You can start the backend now and edit the inventory later;
`CollectorAbsent` then fires for a listed Collector until it reports.

## 2. The monitoring role

Step 2 of the [index](index.md), run inside a database pod so that the password
reaches `psql` through standard input and the environment and appears in no
command line. For a StatefulSet pod `pgdemo-0` in namespace `db`, from the
repository root:

```sh
export OTEL_MONITOR_PASSWORD="$(openssl rand -hex 12)"
{ printf '%s\n' "$OTEL_MONITOR_PASSWORD"; cat packs/postgresql/monitoring-role.sql; } |
  kubectl -n db exec -i pgdemo-0 -- sh -c \
    'read -r OTEL_MONITOR_PASSWORD; export OTEL_MONITOR_PASSWORD; exec psql -U postgres -v ON_ERROR_STOP=1 -q -c "\getenv mon_pw OTEL_MONITOR_PASSWORD" -f -'
```

The first line of standard input is the password, the rest is the script.
On CloudNativePG, run it in the primary's `postgres` container (`-c postgres`,
the primary's name is `kubectl -n db get cluster pgdemo -o
jsonpath='{.status.currentPrimary}'`); the role replicates to the other
instances. The test does exactly this in both targets and fails on an error.
Keep `OTEL_MONITOR_PASSWORD` for step 3.

## 3. What the Collector namespace needs

Four objects, created before the install (the namespace is `obenhub-otel` here,
`OBENHUB_OTEL_NAMESPACE` below). Run from the repository root, with the backend's
files in `deploy/compose/tls/`:

```sh
kubectl create namespace obenhub-otel
kubectl -n obenhub-otel create secret generic obenhub-gateway-tls \
  --from-file=ca.crt=deploy/compose/tls/ca.crt \
  --from-file=tls.crt=deploy/compose/tls/client.crt \
  --from-file=tls.key=deploy/compose/tls/client.key
kubectl -n obenhub-otel create secret generic pg-otel-monitor \
  --from-file=password=<(printf '%s' "$OTEL_MONITOR_PASSWORD")
kubectl -n obenhub-otel create configmap obenhub-pack-postgresql \
  --from-file=packs/postgresql/queries.yaml --from-file=packs/postgresql/queries-slow.yaml
# only with TLS to PostgreSQL (CloudNativePG below); the CA that signed the server certificates
kubectl -n obenhub-otel create configmap obenhub-pg-ca --from-file=ca.crt=<path to that CA certificate>
```

The Secrets and ConfigMaps do not restart pods when they change; after a new
password, query file or CA, run `kubectl -n obenhub-otel rollout restart
daemonset/otelcol-agent-agent`. Keep `ca.key` out of the cluster.

## 4. The values and their variables

`deploy/helm/agent-values.yaml` is for any PostgreSQL pod you can select with a
label rule; `deploy/helm/cnpg-values.yaml` is a second file after it for
CloudNativePG; `deploy/helm/cluster-values.yaml` is the cluster release. They
contain `${VARIABLES}` that `envsubst` fills (the Collector's own `${env:...}`
stays). Their headers say what each variable is:

| Variable | Meaning |
| --- | --- |
| `OBENHUB_GATEWAY_ENDPOINT` | `https://<address given to tls.sh>:4318`, no path |
| `OBENHUB_SERVICE_NAMESPACE` | `service.namespace` of every series; the inventory's `obenhub` |
| `OBENHUB_CLUSTER_NAME` | `obenhub.cluster.name` of the pods this release watches; in CloudNativePG also the Cluster's name |
| `OBENHUB_PG_POD_RULE` | a [receiver_creator](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.165.0/receiver/receivercreator/README.md) expression over the pod, for example `namespace == "db" && labels["app"] == "pgdemo"` (without the namespace condition, pods with that label in any namespace are monitored); the file prefixes `type == "pod" &&`; no single quotes; a pod has the fields `namespace` and `labels` (receiver README at v0.165.0, the pod endpoint table, read 2026-11-27) |
| `OBENHUB_PG_DATABASES` | YAML list of databases the receiver connects to, `[postgres]` or `[postgres, app]` |
| `OBENHUB_PG_SLOW_DATABASE` | the one database the 5-minute slow tier reads |
| `OBENHUB_PG_SSLMODE`, `OBENHUB_PG_TLS_INSECURE` | `verify-ca` and `false`: TLS, chain checked against `obenhub-pg-ca`; `disable` and `true`: no TLS at all (see the StatefulSet section) |
| `OBENHUB_KUBELET_SKIP_VERIFY` | `true` when the kubelet's certificate is self-signed (kind, kubeadm without `serverTLSBootstrap`), else `false` |
| `OBENHUB_OTEL_NAMESPACE` | the namespace of the releases; the agent leaves its own logs out |
| `OBENHUB_PG_NAMESPACE` | cnpg only: namespace of the Cluster, where the JSON logs are parsed |
| `OTELCOL_IMAGE_REPOSITORY`, `OTELCOL_IMAGE_TAG`, `OTELCOL_IMAGE_DIGEST` | the three parts of `OTELCOL_IMAGE` in `deploy/helm/versions.sh` |

Install, with the variables of your target set (the sections below give them):

```sh
. deploy/helm/versions.sh
export OTELCOL_IMAGE_REPOSITORY="${OTELCOL_IMAGE%%:*}" OTELCOL_IMAGE_DIGEST="${OTELCOL_IMAGE#*@}"
r="${OTELCOL_IMAGE#*:}"; export OTELCOL_IMAGE_TAG="${r%%@*}"
# ... the OBENHUB_* variables of your target ...
vars='$OBENHUB_GATEWAY_ENDPOINT $OBENHUB_SERVICE_NAMESPACE $OBENHUB_CLUSTER_NAME $OBENHUB_PG_NAMESPACE $OBENHUB_OTEL_NAMESPACE $OBENHUB_PG_DATABASES $OBENHUB_PG_SLOW_DATABASE $OBENHUB_PG_POD_RULE $OBENHUB_PG_SSLMODE $OBENHUB_PG_TLS_INSECURE $OBENHUB_KUBELET_SKIP_VERIFY $OTELCOL_IMAGE_REPOSITORY $OTELCOL_IMAGE_TAG $OTELCOL_IMAGE_DIGEST'
out="$(mktemp -d)"
for f in agent cnpg cluster; do envsubst "$vars" < "deploy/helm/$f-values.yaml" > "$out/$f-values.yaml"; done
helm repo add otel "$OTEL_CHART_REPO"
helm upgrade --install agent otel/opentelemetry-collector --version "$OTEL_CHART_VERSION" \
  -n obenhub-otel -f "$out/agent-values.yaml" --wait      # CloudNativePG: add  -f "$out/cnpg-values.yaml"
helm upgrade --install cluster otel/opentelemetry-collector --version "$OTEL_CHART_VERSION" \
  -n obenhub-otel -f "$out/cluster-values.yaml" --wait
```

`envsubst` replaces an unset variable with nothing and the Collector then
refuses the configuration or a receiver, so set every variable of the table
that your target uses. Helm merges maps from several `-f` files and replaces
lists; `cnpg-values.yaml` repeats the two lists it changes, and the order
(agent first) matters. The test renders and installs with these commands, with
`helm repo add` into a scratch Helm home and `--kube-context`.

The cluster release's `nodeSelector` is `node-role.kubernetes.io/control-plane`
with a toleration for kubeadm's taint; remove both where the control plane
cannot run pods or is labelled differently. Nothing in it is specific to a
PostgreSQL kind.

## A StatefulSet with the stock `postgres` image

The pods are the user's own; the Collector only needs a label to select them.
This is the test's target, written as a user would write it: a headless
Service, a StatefulSet with one replica of the stock image (the
`postgres:18.7-trixie` digest `install-test.sh` and the
[container page](container.md) use), a generated superuser password in a
Secret, and a volume claim. The image's own defaults stay: no
`pg_stat_statements`, no TLS, `pg_hba.conf` as the image writes it. The data
volume is mounted at `/var/lib/postgresql`: the image declares that as its
`VOLUME` and sets `PGDATA=/var/lib/postgresql/18/docker` (`docker image inspect`
of the pinned image, read 2026-11-27).

```sh
kubectl create namespace db
kubectl -n db create secret generic pg-superuser \
  --from-file=password=<(openssl rand -hex 12 | tr -d '\n')
kubectl -n db apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: pgdemo
  labels: {app: pgdemo}
spec:
  clusterIP: None
  selector: {app: pgdemo}
  ports:
    - {name: postgres, port: 5432}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pgdemo
spec:
  serviceName: pgdemo
  replicas: 1
  selector:
    matchLabels: {app: pgdemo}
  template:
    metadata:
      labels: {app: pgdemo}
    spec:
      containers:
        - name: postgres
          image: postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
          ports:
            - {name: postgres, containerPort: 5432}
          env:
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: pg-superuser, key: password}}
          readinessProbe:
            exec: {command: [pg_isready, -U, postgres, -h, 127.0.0.1]}
            periodSeconds: 5
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        resources: {requests: {storage: 1Gi}}
YAML
kubectl -n db rollout status statefulset/pgdemo --timeout=300s
```

The readiness probe asks over TCP: the image starts a temporary server on a
socket for its init scripts and restarts it, so the pod is ready only for the
final server. Then step 2 (the role, pod `pgdemo-0`), the objects of step 3
without `obenhub-pg-ca`, and the variables:

```sh
export OBENHUB_GATEWAY_ENDPOINT=https://192.0.2.10:4318 OBENHUB_SERVICE_NAMESPACE=obenhub \
  OBENHUB_CLUSTER_NAME=pgdemo OBENHUB_PG_NAMESPACE=db OBENHUB_OTEL_NAMESPACE=obenhub-otel \
  OBENHUB_PG_DATABASES='[postgres]' OBENHUB_PG_SLOW_DATABASE=postgres \
  OBENHUB_PG_POD_RULE='namespace == "db" && labels["app"] == "pgdemo"' \
  OBENHUB_PG_SSLMODE=disable OBENHUB_PG_TLS_INSECURE=true OBENHUB_KUBELET_SKIP_VERIFY=false
```

then the install of step 4 with `agent-values.yaml` only (the test sets
`OBENHUB_KUBELET_SKIP_VERIFY=true` because kind's kubelet certificate is
self-signed).

**No TLS to PostgreSQL.** The stock image has no server certificate, and
PostgreSQL's `ssl` setting is off by default
([runtime-config-connection](https://www.postgresql.org/docs/18/runtime-config-connection.html)),
so this mode sets `sslmode=disable` for the query receivers and no TLS for the
PostgreSQL receiver. With `scram-sha-256` (the image's default for its `host`
rule) the password itself is not sent, but the query results cross the pod
network in clear text. To change that, give the server `ssl = on` with a
certificate, put the CA that signed it in `obenhub-pg-ca` and use `verify-ca`
and `false`, as the CloudNativePG section does; the test did not run that for a
StatefulSet.

The Collector's identity of a pod is its name (`service.instance.id`
`pgdemo-0`), and the container's log lines arrive as the container wrote them,
with the pod's Kubernetes attributes: the stock image logs plain text to standard
error, so they are not parsed, and the PostgreSQL log panel of the dashboard
(which reads parsed jsonlog records) stays empty.

## CloudNativePG

The operator is applied from its release manifest, pinned in
`lab/k8s/versions.sh` (`CNPG_VERSION`, `CNPG_MANIFEST_URL`,
`CNPG_MANIFEST_SHA256`: the checksum of the downloaded manifest, which the
release does not publish). Check it before applying, as the test does, and
wait for the operator:

```sh
. lab/k8s/versions.sh
curl -fsSL -o cnpg.yaml "$CNPG_MANIFEST_URL"
echo "$CNPG_MANIFEST_SHA256  cnpg.yaml" | sha256sum -c -
kubectl apply --server-side -f cnpg.yaml
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s
```

The Cluster is the smallest a user writes: two instances, the operand image the
lab pins (`PG_IMAGE` of the same file; the operator's default image is a tag,
not a digest) and a volume. Everything else is CloudNativePG's default,
including its exporter on port 9187 and its default monitoring queries. The
namespace is `db`. Five Kubernetes panels of the CloudNativePG dashboard
(container restarts and readiness, pod CPU, memory and network) read the
dashboard variable `namespace` (values of `k8s.namespace.name` of
`k8s.pod.phase`; the dashboard's default is `obenhub`, the lab's namespace), so
choose your namespace in the dropdown. The test passes it to
`scripts/check-panels.sh` as its sixth argument.

```sh
kubectl create namespace db
kubectl -n db apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pgdemo
spec:
  instances: 2
  imageName: $PG_IMAGE
  storage:
    size: 1Gi
YAML
kubectl -n db get cluster pgdemo -w   # until "Cluster in healthy state", 2 ready instances
```

The first apply can fail while the operator's webhook is not ready yet; the test
retries every 10 s up to 12 times. Then step 2 on the primary (`-c postgres`),
and the CA of the instances' server certificates for step 3, from the Secret
the operator creates (`<cluster>-ca`; the lab reads `pg-ca` the same way):

```sh
kubectl -n db get secret pgdemo-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > pg-ca.crt
```

The variables, then the install of step 4 with both files, `agent-values.yaml`
first:

```sh
export OBENHUB_CLUSTER_NAME=pgdemo OBENHUB_PG_NAMESPACE=db \
  OBENHUB_PG_DATABASES='[postgres, app]' OBENHUB_PG_SLOW_DATABASE=app \
  OBENHUB_PG_POD_RULE='namespace == "db" && labels["cnpg.io/cluster"] == "pgdemo" && labels["cnpg.io/podRole"] == "instance"' \
  OBENHUB_PG_SSLMODE=verify-ca OBENHUB_PG_TLS_INSECURE=false
# and the gateway, service namespace, Collector namespace, kubelet and image variables as above
```

`app` is the database CloudNativePG's default bootstrap creates. TLS is on:
the query receivers verify the chain against the CA (`verify-ca`); the server
certificate names only the Cluster's Services, never a pod, so the pod address
cannot be verified, and the PostgreSQL receiver (which supports only
`verify-full` or no verification) uses TLS without verifying the certificate
(`agent-values.yaml` comment).

What `cnpg-values.yaml` adds over the base: the instance manager's exporter
(`cnpg_collector_*`, operator state only; the PostgreSQL metrics come from the
pack, so the exporter's `cnpg_pg_*` default queries and the Go runtime series are
dropped), the identity `service.name` `postgresql` and the pod as instance for
the `postgres` container's logs, and the parsing of CloudNativePG's JSON log
lines into the body and attributes the PostgreSQL log panel reads. Instances are
named by the operator (`pgdemo-1`, `pgdemo-2`); the PostgreSQL dashboard is
opened for the primary (`kubectl -n db get cluster pgdemo -o
jsonpath='{.status.currentPrimary}'`), the CloudNativePG dashboard shows both.

## Limitations

- **One node.** The test's cluster has one node, so one agent Pod. On several
  nodes the DaemonSet runs one agent per node, each reading only the pods of
  its node (`k8s_observer` with `node:`); each needs its own inventory entry
  (`otelcol-agent-<node>`) and the targets name the agent of their node. The
  chart renders no `tolerations` for the agent by default (`helm template` of the
  agent values, read 2026-11-27): a node tainted for
  databases needs `tolerations` in your own values file. Not tested.
- **Container logs of every pod on the node** go to VictoriaLogs (the preset
  reads `/var/log/pods/*/*/*.log`; only the Collectors' own are excluded). Mind
  the volume on a busy node. Narrowing it is a change to `file_log` that was not
  tested.
- **The agent runs as root** with a `hostPath` for its offsets, which a restricted
  Pod Security profile forbids (the comment in `agent-values.yaml` says what to do
  instead; not tested).
- **Failover and replacement** change pod names: edit the inventory and reload
  vmalert. The test does not exercise failover, a rolling update of the
  database, or the Collector's behaviour while a pod restarts (the lab's
  scenarios do that for CloudNativePG, `lab/k8s/`).
- **Not tested**: Helm 3, other Kubernetes versions or distributions (the managed ones of the big clouds,
  k3s), arm64, more than two CloudNativePG instances, PostgreSQL in several
  namespaces, a Collector upgrade, other operators (Zalando, Crunchy, Percona),
  pgBackRest or PgBouncer next to the pods, and a server with TLS in a plain
  StatefulSet.
- **Host panels**: the host pack (hostmetrics, journald) is not in the Helm
  values, so the host dashboard has no data; node and pod resources come from
  the kubelet (`kubeletstats`) and the `k8s_cluster` receiver.

## What you should see

[Step 4 of the index](index.md#4-what-you-should-see) with the instance names
of your pods: the heartbeat query takes `"service.instance.id"="<pod name>"` and
`"obenhub.cluster.name"="<OBENHUB_CLUSTER_NAME>"`, and the PostgreSQL dashboard's
variables are the same pair (`scripts/check-panels.sh
packs/postgresql/dashboards/postgresql.json http://127.0.0.1:3000
deploy/compose/.env <pod> <cluster>`; for `packs/cnpg/dashboards/cnpg.json` add `"" "" <namespace>`). Without `pg_stat_statements` the four
"Statements" panels are empty (see the index). The host dashboard has no data
here: the host pack is not part of these values.

## Take it down

```sh
helm -n obenhub-otel uninstall agent cluster
kubectl delete namespace obenhub-otel
```

Then step 5 of the [index](index.md#5-take-it-down) for the backend. The test
deletes its whole kind cluster instead, with `kind delete cluster --name
obenhub-g1c` (never any other name), takes the compose project down and removes
its scratch directory; a failure of any of that fails the run.

## Run the test yourself

```sh
mise run deploy:k8s-test -- sts     # or: -- cnpg
```

Needs Docker, `kind`, `kubectl`, `helm`, `jq`, `curl`, `openssl` and `envsubst`;
the `mise` task runs the script with the versions `mise.k8s.toml` pins, and the
script refuses other versions (`lab/k8s/scripts/check-tools.sh`). One target per
run, about 30 minutes (1020 s of it the settle; on a loaded machine the cluster,
the images and the backend's Grafana can take several minutes each), not part of
`mise run check`. It appends a line with `"test": "k8s-sts-test"` or
`"k8s-cnpg-test"` to `deploy/results/runs.jsonl` and prints a final
`k8s-<target>-test: PASS in <n>s, ...` line; set `K8S_TEST_EVIDENCE=0` to skip the
line. `K8S_TEST_ADDR` (default `10.0.0.11`) is this machine's address as the pods
reach it, and goes into the gateway certificate; `K8S_TEST_PORT_BASE` (default
61200) moves the backend's six ports. The test brings the backend up last,
right before the Collectors, so that the inventory does not wait for them.

Before it creates anything it checks, read-only, and refuses (exit 2, no line)
when a kind cluster `obenhub-g1c` or a container named `obenhub-g1c-*` exists,
the tools are not the pinned ones, inotify's limits are below kind's
known-issues values, a port is taken, or (cnpg) the operator manifest does not
match its pinned checksum. It never touches another kind cluster (the lab's is
`obenhub`) or your kubeconfig: the cluster's kubeconfig and Helm's state live in
the test's temporary directory. On exit it deletes only `obenhub-g1c`.
