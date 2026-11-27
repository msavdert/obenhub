#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install test of docs/guides/monitor/kubernetes.md (roadmap G1c): the backend
# of deploy/compose on this machine, and in a kind cluster of its own a
# PostgreSQL built without the lab's files, watched by the upstream
# opentelemetry-collector Helm chart with the values of deploy/helm. One
# target per run:
#   sts   a StatefulSet running the stock postgres image (the pin of
#         install-test.sh), default configuration, no pg_stat_statements; the
#         release "agent" with agent-values.yaml only
#   cnpg  the CloudNativePG operator (the pinned manifest of
#         lab/k8s/versions.sh, its sha256 checked) and a two-instance Cluster
#         with default settings; the release "agent" with agent-values.yaml and
#         cnpg-values.yaml
# plus the release "cluster" (cluster-values.yaml) in both. It then runs the
# assertions of install-test.sh (lib.sh): the heartbeat of every instance
# pod, nothing but Watchdog firing, the dead-man cadence, the panels of the
# PostgreSQL dashboard (and the CloudNativePG one for cnpg), and that the
# database pod's container logs and the Kubernetes metrics are in the backend.
# One JSON line per run goes to deploy/results/runs.jsonl ("test":
# "k8s-sts-test" or "k8s-cnpg-test"). Needs docker, kind, kubectl, helm, jq,
# curl, openssl, envsubst on this machine (the pinned versions of
# mise.k8s.toml: run it as `mise run deploy:k8s-test <sts|cnpg>`); takes about
# 30 minutes. Not part of `mise run check`.
#   mise run deploy:k8s-test -- <sts|cnpg>
# Environment: K8S_TEST_ADDR (this machine's address as the pods reach it, goes
# into the gateway certificate; default 10.0.0.11), K8S_TEST_PORT_BASE (default
# 61200; six ports from there are bound, the gateway's on K8S_TEST_ADDR when
# that is an IPv4 address, the others on 127.0.0.1), K8S_TEST_EVIDENCE=0 to
# skip the runs.jsonl line, K8S_TEST_SETTLE=<seconds> to shorten the settle
# while debugging (no evidence line then).
#
# The gateway is reached at K8S_TEST_ADDR, as the VM test does, and not at the
# kind network's gateway address: a pod reaches any address of this machine
# through the node and the Docker bridge, and the address is one a user's
# cluster can reach too. The backend is brought up last, right before the
# Collectors, so that its inventory does not wait minutes for them.
#
# Fail closed: every refusal check runs, read-only, before the script creates
# anything, and a refusal writes no evidence line (exit 2). It refuses when a
# kind cluster named obenhub-g1c exists or a container whose name starts with
# obenhub-g1c-, when the tools are not the pinned ones, when inotify limits are
# below kind's known-issues values, when a port is taken, and (cnpg) when the
# operator manifest does not match the sha256 of lab/k8s/versions.sh. It never
# touches another kind cluster (the lab's is obenhub) or the kubeconfig of the
# user: the cluster's kubeconfig is a file in the test's temporary directory. On
# exit it deletes only the cluster obenhub-g1c, takes the compose project down
# and removes its temporary directory; a teardown failure, or a cluster or
# container still there afterwards, fails the run and the evidence line.
# shellcheck disable=SC2329  # functions are called from the EXIT trap, settle_wait and backend_up
set -euo pipefail

# shellcheck source=deploy/test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

target="${1:-}"
case "$target" in
  sts | cnpg) [ $# -eq 1 ] || target="" ;;
  *) target="" ;;
esac
[ -n "$target" ] || { echo "usage: k8s-test.sh <sts|cnpg>   (see the header for the environment)" >&2; exit 2; }

TEST_NAME="k8s-$target-test"
ENV_PREFIX=K8S_TEST
project="obenhub-k8s-$target-test"
cluster=obenhub-g1c   # literal use below: kind delete is only ever given this name
kctx="kind-$cluster"
node="$cluster-control-plane"
db_ns=db
otel_ns=obenhub-otel
dbname=pgdemo   # StatefulSet, Service, CloudNativePG Cluster and obenhub.cluster.name

refuse() { echo "k8s-test: $*" >&2; exit 2; }

# the pins: kind node image and CloudNativePG from the lab, the Collector chart and
# image from deploy/helm (check-deploy-pins.py keeps them equal to the lab's)
# shellcheck source=lab/k8s/versions.sh
. "$repo/lab/k8s/versions.sh"   # sets KIND_CLUSTER=obenhub too, which this script never uses
CNPG_PG_IMAGE=$PG_IMAGE
# shellcheck source=deploy/helm/versions.sh
. "$repo/deploy/helm/versions.sh"
# the stock image of the container page and the install test
STS_PG_IMAGE=$(sed -n 's/^PG_IMAGE=//p' "$repo/deploy/test/install-test.sh")
[ -n "$STS_PG_IMAGE" ] || refuse "PG_IMAGE not found in install-test.sh"

addr="${K8S_TEST_ADDR:-10.0.0.11}"
base="${K8S_TEST_PORT_BASE:-61200}"
p_grafana=$base p_vm=$((base + 1)) p_vl=$((base + 2)) p_vmalert=$((base + 3)) p_am=$((base + 4)) p_gw=$((base + 5))
lib_check_ports "set K8S_TEST_PORT_BASE"
gateway_bind=0.0.0.0
if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then gateway_bind=$addr; fi

# ---- preflight: read-only, and every refusal before the first change
for c in docker kind kubectl helm jq curl openssl envsubst sha256sum ss ip sysctl base64 awk sed grep mktemp git seq; do
  command -v "$c" >/dev/null || refuse "$c is not on PATH (run it as: mise run deploy:k8s-test -- $target)"
done
"$repo/lab/k8s/scripts/check-tools.sh" >/dev/null 2>&1 \
  || refuse "the tools on PATH are not the ones mise.k8s.toml pins (run it as: mise run deploy:k8s-test -- $target; details: MISE_ENV=k8s mise exec -- lab/k8s/scripts/check-tools.sh)"
if kind get clusters 2>/dev/null | grep -qx "$cluster"; then refuse "a kind cluster $cluster exists; delete it yourself (never forced): kind delete cluster --name $cluster"; fi
if [ -n "$(docker ps -aq --filter "name=^$cluster-")" ]; then refuse "containers named $cluster-* exist; remove them yourself (never forced)"; fi
if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]; then refuse "containers of the compose project $project exist; remove them yourself (never forced)"; fi
watches="$(sysctl -n fs.inotify.max_user_watches)"
instances="$(sysctl -n fs.inotify.max_user_instances)"
if [ "$watches" -lt 524288 ] || [ "$instances" -lt 512 ]; then
  refuse "inotify too low: max_user_watches=$watches (kind needs 524288), max_user_instances=$instances (512); not changing sysctls"
fi
if [ "$gateway_bind" != 0.0.0.0 ] && ! ip -4 -o addr show | grep -q "inet $addr/"; then
  refuse "K8S_TEST_ADDR $addr is not an address of this machine"
fi
if [ "$target" = cnpg ]; then
  pre="$(mktemp -d)"
  trap 'rm -rf "${pre:?}"' EXIT   # replaced by lib_init's trap once the file has moved
  curl -fsSL --retry 3 -o "$pre/cnpg.yaml" "$CNPG_MANIFEST_URL" || refuse "cannot download $CNPG_MANIFEST_URL"
  got=$(sha256sum "$pre/cnpg.yaml" | cut -d' ' -f1)
  [ "$got" = "$CNPG_MANIFEST_SHA256" ] || refuse "CloudNativePG manifest $CNPG_MANIFEST_URL has sha256 $got, lab/k8s/versions.sh has $CNPG_MANIFEST_SHA256"
fi

lib_init
settle_packs="collector host postgresql"
[ "$target" = sts ] || settle_packs="$settle_packs cnpg k8s"
if [ "$target" = cnpg ]; then mv "$pre/cnpg.yaml" "$tmp/cnpg.yaml"; rmdir "$pre"; fi
declare -A panel_legit=()
panels_not_run='[]'
EVIDENCE_EXTRA='{}'

# the cluster's own kubeconfig, and helm's state, in the temporary directory
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CONFIG_HOME="$tmp/helm/config" HELM_CACHE_HOME="$tmp/helm/cache" HELM_DATA_HOME="$tmp/helm/data"
k() { kubectl --context "$kctx" "$@"; }

a_kind=false
teardown() {
  set +e
  if $a_kind; then
    kind delete cluster --name obenhub-g1c --kubeconfig "$tmp/kubeconfig" >/dev/null 2>&1 || fail "teardown: kind delete cluster obenhub-g1c"
    kind get clusters 2>/dev/null | grep -qx obenhub-g1c && fail "teardown: kind cluster obenhub-g1c still exists"
    [ -z "$(docker ps -aq --filter "name=^obenhub-g1c-")" ] || fail "teardown: containers named obenhub-g1c-* still exist"
  fi
  backend_down
  tmp_remove
}
collector_alive() {
  [ "$(k -n "$otel_ns" get daemonset otelcol-agent-agent -o jsonpath='{.status.numberReady}' 2>/dev/null)" = 1 ] \
    && [ "$(k -n "$otel_ns" get deployment otelcol-cluster -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ]
}
collector_diag() { k -n "$otel_ns" get pods; k -n "$otel_ns" logs daemonset/otelcol-agent-agent --tail 30; k -n "$otel_ns" logs deployment/otelcol-cluster --tail 30; }

# wait_until <seconds> <what> <command...>: poll every 5 s
wait_until() {
  local limit=$1 what=$2 end
  shift 2
  end=$(( $(date +%s) + limit ))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$end" ] || { fail "timed out after ${limit}s waiting for $what"; k get pods -A | tail -30 >&2; exit 1; }
    sleep 5
  done
}

# ---- a. the kind cluster: one node, the pinned node image, nothing else asked of it
log "kind: create cluster $cluster ($KIND_NODE_IMAGE)"
kind create cluster --name "$cluster" --image "$KIND_NODE_IMAGE" --kubeconfig "$tmp/kubeconfig" --wait 180s >"$tmp/kind.log" 2>&1 \
  || { cat "$tmp/kind.log" >&2; fail "kind create cluster"; exit 1; }
a_kind=true   # only now: if another run created the name between preflight and create, our create failed above and teardown must not delete theirs
k_version=$(k version -o json | jq -r '.serverVersion.gitVersion')
log "cluster: Kubernetes $k_version"
monpw="$(openssl rand -hex 12)"

# the monitoring role of step 2 of the guide, in a pod; the password reaches
# psql through stdin and the environment, not argv. $1 is the pod, $2... extra kubectl exec flags
apply_role() {
  local pod=$1
  shift
  { printf '%s\n' "$monpw"; cat "$repo/packs/postgresql/monitoring-role.sql"; } \
    | k -n "$db_ns" exec -i "$@" "$pod" -- sh -c 'read -r OTEL_MONITOR_PASSWORD; export OTEL_MONITOR_PASSWORD; exec psql -U postgres -v ON_ERROR_STOP=1 -q -c "\\getenv mon_pw OTEL_MONITOR_PASSWORD" -f -' >/dev/null \
    || fail "monitoring-role.sql"
}

# ---- b. the database, written the way a user would
k create namespace "$db_ns" >/dev/null
pgc=()   # kubectl exec flags: CloudNativePG pods have more than one container
case "$target" in
  sts)
    pg_image=$STS_PG_IMAGE
    pg_pods=("$dbname-0")
    primary="$dbname-0"
    k -n "$db_ns" create secret generic pg-superuser --from-file=password=<(openssl rand -hex 12 | tr -d '\n') >/dev/null
    k -n "$db_ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: $dbname
  labels: {app: $dbname}
spec:
  clusterIP: None
  selector: {app: $dbname}
  ports:
    - {name: postgres, port: 5432}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $dbname
spec:
  serviceName: $dbname
  replicas: 1
  selector:
    matchLabels: {app: $dbname}
  template:
    metadata:
      labels: {app: $dbname}
    spec:
      containers:
        - name: postgres
          image: $pg_image
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
    log "target: StatefulSet $dbname ($pg_image)"
    k -n "$db_ns" rollout status "statefulset/$dbname" --timeout=300s || fail "statefulset $dbname not ready"
    # the image restarts the server once after its init scripts; the probe uses TCP, so ready means the final server
    apply_role "$primary"
    pod_rule="namespace == \"$db_ns\" && labels[\"app\"] == \"$dbname\""
    sslmode=disable tls_insecure=true
    databases='[postgres]' slow_db=postgres
    values_files=(agent)
    ;;
  cnpg)
    pg_image=$CNPG_PG_IMAGE
    log "target: CloudNativePG $CNPG_VERSION (manifest sha256 checked), Cluster $dbname ($pg_image)"
    k apply --server-side -f "$tmp/cnpg.yaml" >/dev/null
    k -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s
    applied=false
    for _ in $(seq 12); do
      if k -n "$db_ns" apply -f - >"$tmp/cluster-apply.log" 2>&1 <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $dbname
spec:
  instances: 2
  imageName: $pg_image
  storage:
    size: 1Gi
YAML
      then applied=true; break; fi
      sleep 10   # the operator's webhook can lag its rollout
    done
    $applied || { cat "$tmp/cluster-apply.log" >&2; fail "applying the Cluster"; exit 1; }
    cluster_ready() {
      local ph ready
      ph=$(k -n "$db_ns" get cluster "$dbname" -o jsonpath='{.status.phase}') || return 1
      ready=$(k -n "$db_ns" get cluster "$dbname" -o jsonpath='{.status.readyInstances}') || return 1
      [ "$ph" = "Cluster in healthy state" ] && [ "$ready" = 2 ]
    }
    wait_until 900 "a healthy Cluster with two ready instances" cluster_ready
    primary=$(k -n "$db_ns" get cluster "$dbname" -o jsonpath='{.status.currentPrimary}')
    mapfile -t pg_pods < <(k -n "$db_ns" get pods -l "cnpg.io/cluster=$dbname,cnpg.io/podRole=instance" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    log "target: instances ${pg_pods[*]}, primary $primary"
    pgc=(-c postgres)
    apply_role "$primary" -c postgres
    pod_rule="namespace == \"$db_ns\" && labels[\"cnpg.io/cluster\"] == \"$dbname\" && labels[\"cnpg.io/podRole\"] == \"instance\""
    sslmode=verify-ca tls_insecure=false
    databases='[postgres, app]' slow_db=app
    values_files=(agent cnpg)
    ;;
esac
pgv=$(k -n "$db_ns" exec "$primary" "${pgc[@]}" -- psql -U postgres -Atc 'SELECT version()')
log "server: $pgv"
# the login the Collector will use, over TCP to the pod, as that pod sees it
pg_ip=$(k -n "$db_ns" get pod "$primary" -o jsonpath='{.status.podIP}')
whoami=$(printf '%s\n' "$monpw" | k -n "$db_ns" exec -i "$primary" "${pgc[@]}" -- sh -c "read -r PGPASSWORD; export PGPASSWORD; psql -h $pg_ip -U otel_monitor -d postgres -Atc 'SELECT current_user'" 2>&1 || true)
[ "$whoami" = otel_monitor ] || fail "otel_monitor cannot log in over TCP to $pg_ip: $whoami"

# ---- c. backend, last: its inventory expects what is now running
backend_prepare() {
  local t
  {
    cat <<YAML
# the test's inventory: what the k8s run installs (see deploy/compose/inventory.yml)
groups:
  - name: inventory
    interval: 15s
    rules:
      - record: obenhub.expected_collector
        expr: |
          union(
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-gateway"),
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-agent-$node", "obenhub.upstream", "otelcol-gateway"),
            label_set(vector(1), "service.namespace", "obenhub", "service.instance.id", "otelcol-cluster", "obenhub.upstream", "otelcol-gateway")
          )

      - record: obenhub.expected_target
        expr: |
          union(
YAML
    for t in "${pg_pods[@]}"; do
      sep=,
      [ "$t" != "${pg_pods[-1]}" ] || sep=
      echo "            label_set(vector(1), \"service.namespace\", \"obenhub\", \"service.name\", \"postgresql\", \"obenhub.cluster.name\", \"$dbname\", \"service.instance.id\", \"$t\", \"obenhub.collector\", \"otelcol-agent-$node\")$sep"
    done
    echo "          )"
  } >"$cdir/inventory.yml"
}
backend_up "$addr"
gwurl="https://$addr:$p_gw"
docker exec "$node" bash -c "timeout 5 bash -c '</dev/tcp/$addr/$p_gw'" || fail "the gateway $addr:$p_gw is not reachable from the kind node"

# ---- d. the Collector releases: the steps of kubernetes.md
k create namespace "$otel_ns" >/dev/null
k -n "$otel_ns" create secret generic obenhub-gateway-tls --from-file=ca.crt="$cdir/tls/ca.crt" \
  --from-file=tls.crt="$cdir/tls/client.crt" --from-file=tls.key="$cdir/tls/client.key" >/dev/null
k -n "$otel_ns" create secret generic pg-otel-monitor --from-file=password=<(printf '%s' "$monpw") >/dev/null
k -n "$otel_ns" create configmap obenhub-pack-postgresql --from-file="$repo/packs/postgresql/queries.yaml" \
  --from-file="$repo/packs/postgresql/queries-slow.yaml" >/dev/null
if [ "$sslmode" != disable ]; then
  k -n "$db_ns" get secret "$dbname-ca" -o jsonpath='{.data.ca\.crt}' | base64 -d >"$tmp/pg-ca.crt"
  k -n "$otel_ns" create configmap obenhub-pg-ca --from-file=ca.crt="$tmp/pg-ca.crt" >/dev/null
fi

export OTELCOL_IMAGE_REPOSITORY="${OTELCOL_IMAGE%%:*}" OTELCOL_IMAGE_DIGEST="${OTELCOL_IMAGE#*@}"
r="${OTELCOL_IMAGE#*:}"
export OTELCOL_IMAGE_TAG="${r%%@*}"
export OBENHUB_GATEWAY_ENDPOINT="$gwurl" OBENHUB_SERVICE_NAMESPACE=obenhub OBENHUB_CLUSTER_NAME="$dbname" \
  OBENHUB_PG_NAMESPACE="$db_ns" OBENHUB_OTEL_NAMESPACE="$otel_ns" OBENHUB_PG_DATABASES="$databases" OBENHUB_PG_SLOW_DATABASE="$slow_db" \
  OBENHUB_PG_POD_RULE="$pod_rule" OBENHUB_PG_SSLMODE="$sslmode" OBENHUB_PG_TLS_INSECURE="$tls_insecure" \
  OBENHUB_KUBELET_SKIP_VERIFY=true   # kind's kubelet serves a self-signed certificate
# shellcheck disable=SC2016  # envsubst takes the names, not their values
vars='$OBENHUB_GATEWAY_ENDPOINT $OBENHUB_SERVICE_NAMESPACE $OBENHUB_CLUSTER_NAME $OBENHUB_PG_NAMESPACE $OBENHUB_OTEL_NAMESPACE $OBENHUB_PG_DATABASES $OBENHUB_PG_SLOW_DATABASE $OBENHUB_PG_POD_RULE $OBENHUB_PG_SSLMODE $OBENHUB_PG_TLS_INSECURE $OBENHUB_KUBELET_SKIP_VERIFY $OTELCOL_IMAGE_REPOSITORY $OTELCOL_IMAGE_TAG $OTELCOL_IMAGE_DIGEST'
install -d "$tmp/values"
for f in agent cnpg cluster; do envsubst "$vars" <"$repo/deploy/helm/$f-values.yaml" >"$tmp/values/$f-values.yaml"; done
helm repo add otel "$OTEL_CHART_REPO" >/dev/null
agent_args=()
for f in "${values_files[@]}"; do agent_args+=(-f "$tmp/values/$f-values.yaml"); done
log "helm: install agent (${values_files[*]}) and cluster, chart $OTEL_CHART_VERSION"
helm upgrade --install agent otel/opentelemetry-collector --version "$OTEL_CHART_VERSION" --kube-context "$kctx" \
  -n "$otel_ns" "${agent_args[@]}" --wait --timeout 5m >"$tmp/helm-agent.log" 2>&1 || { cat "$tmp/helm-agent.log" >&2; collector_diag >&2; fail "helm install agent"; exit 1; }
helm upgrade --install cluster otel/opentelemetry-collector --version "$OTEL_CHART_VERSION" --kube-context "$kctx" \
  -n "$otel_ns" -f "$tmp/values/cluster-values.yaml" --wait --timeout 5m >"$tmp/helm-cluster.log" 2>&1 || { cat "$tmp/helm-cluster.log" >&2; collector_diag >&2; fail "helm install cluster"; exit 1; }
tcol=$(date +%s)
k -n "$otel_ns" get pods
# a quiet database logs nothing for minutes: make it log one ERROR line after the
# Collectors started, so that the log assertion below does not depend on a checkpoint
k -n "$db_ns" exec "$primary" "${pgc[@]}" -- psql -U postgres -Atc 'SELECT 1/0' >/dev/null 2>&1 || true

kindv=$(kind version | awk '{print $2}')
helmv=$(helm version --short)
EVIDENCE_IMAGES="$pg_image $KIND_NODE_IMAGE $OTELCOL_IMAGE"
EVIDENCE_EXTRA=$(jq -nc --arg tg "$target" --arg kv "$k_version" --arg kind "$kindv" --arg helm "$helmv" --arg chart "$OTEL_CHART_VERSION" \
  --arg pg "$pgv" --arg vals "${values_files[*]}" --arg sslmode "$sslmode" --arg addr "$addr" --arg cnpg "${CNPG_VERSION:-}" \
  --argjson pods "$(printf '%s\n' "${pg_pods[@]}" | jq -R . | jq -sc .)" \
  '{target: ({environment: "kind cluster, one node, built by the test", workload: (if $tg == "sts" then "StatefulSet, stock postgres image, default configuration" else "CloudNativePG Cluster, two instances, default settings" end),
     kubernetes: $kv, kind_version: $kind, helm: $helm, chart: $chart, agent_values: ($vals | split(" ")), postgresql: $pg, instance_pods: $pods,
     pg_tls: ($sslmode + (if $sslmode == "disable" then " (stock image has no server certificate)" else "" end)),
     gateway: ("https://" + $addr + " from the pods")} + (if $tg == "cnpg" then {cnpg_version: $cnpg} else {} end))}')

# ---- e. settle and assert
settle_wait collector_alive collector_diag
restarts=$(k -n "$otel_ns" get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{" "}{end}')
log "Collector pod restarts: ${restarts:-none}"
for n in $restarts; do [ "$n" = 0 ] || fail "a Collector container restarted $n times"; done
{ k -n "$otel_ns" logs daemonset/otelcol-agent-agent; k -n "$otel_ns" logs deployment/otelcol-cluster; } >"$tmp/collector.log" 2>&1 || true
nerr=$(grep -ci 'error' "$tmp/collector.log" || true)
echo "Collector log lines with \"error\" since the start: ${nerr:-0}"
grep -i 'error' "$tmp/collector.log" | cut -c1-300 | sort | uniq -c | sort -rn | head -10 || true
EVIDENCE_EXTRA=$(jq -c --argjson n "${nerr:-0}" '.target.collector_log_error_lines = $n' <<<"$EVIDENCE_EXTRA")

# the heartbeat of every instance pod, as one series each
hb_matcher="\"service.instance.id\"=~\"$(IFS='|'; echo "${pg_pods[*]}")\",\"obenhub.cluster.name\"=\"$dbname\""
hb_expect=${#pg_pods[@]}
grace_collectors="otelcol-agent-$node otelcol-cluster"
assert_backend

# what the page promises besides the dashboards: Kubernetes metrics, and the
# container logs of the database pod, in the backend
vm="http://127.0.0.1:$p_vm" vl="http://127.0.0.1:$p_vl"
for m in k8s.pod.phase k8s.pod.cpu.time; do
  n=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode "query=count(last_over_time({__name__=\"$m\",\"k8s.pod.name\"=\"$primary\"}[5m]))" | jq -r '.data.result[0].value[1] // "0"')
  log "series $m of pod $primary: $n"
  [ "$n" -gt 0 ] || fail "no $m series of pod $primary in VictoriaMetrics"
done
nl=$(curl -fsS --max-time 20 "$vl/select/logsql/query" --data-urlencode "query=k8s.pod.name:$primary k8s.namespace.name:$db_ns _time:30m | stats count() c" | jq -r '.c // "0"')
log "container log records of pod $primary in VictoriaLogs: $nl"
[ "${nl:-0}" -gt 0 ] || fail "no container log record of pod $primary in VictoriaLogs"
# the record of the deliberate SELECT 1/0 above, so a quiet database cannot pass by other lines
nz=$(curl -fsS --max-time 20 "$vl/select/logsql/query" --data-urlencode "query=k8s.pod.name:$primary k8s.namespace.name:$db_ns _time:30m \"division by zero\" | stats count() c" | jq -r '.c // "0"')
log "records of the SELECT 1/0 error of pod $primary: $nz"
[ "${nz:-0}" -gt 0 ] || fail "no 'division by zero' log record of pod $primary in VictoriaLogs"
EVIDENCE_EXTRA=$(jq -c --argjson n "${nl:-0}" '.target.container_log_records_of_primary = $n' <<<"$EVIDENCE_EXTRA")
if [ "$target" = cnpg ]; then
  ncu=$(curl -fsS --max-time 20 "$vm/api/v1/query" --data-urlencode "query=count(last_over_time({__name__=\"cnpg_collector_up\",\"obenhub.cluster.name\"=\"$dbname\"}[2m]))" | jq -r '.data.result[0].value[1] // "0"')
  log "series cnpg_collector_up of cluster $dbname: $ncu"
  [ "$ncu" = "${#pg_pods[@]}" ] || fail "cnpg_collector_up series: $ncu, want ${#pg_pods[@]}"
  nj=$(curl -fsS --max-time 20 "$vl/select/logsql/query" --data-urlencode "query=service.name:postgresql obenhub.cluster.name:$dbname _time:30m | stats count() c" | jq -r '.c // "0"')
  log "parsed PostgreSQL log records of cluster $dbname in VictoriaLogs: $nj"
  [ "${nj:-0}" -gt 0 ] || fail "no parsed PostgreSQL log record (service.name postgresql) of cluster $dbname in VictoriaLogs"
  EVIDENCE_EXTRA=$(jq -c --argjson n "${nj:-0}" '.target.cnpg_parsed_postgresql_log_records = $n' <<<"$EVIDENCE_EXTRA")
fi

# panels: the PostgreSQL dashboard for the primary pod; the CloudNativePG one for cnpg.
# The host dashboard is not run: the host pack's receivers are not part of the Helm
# values (a pod's host is the node, read by kubeletstats instead).
panel_runs=("$repo/packs/postgresql/dashboards/postgresql.json|$primary|$dbname")
panels_not_run='[{"dashboard": "host", "reason": "the host pack is not part of the Helm values; node metrics come from kubeletstats"}]'
if [ "$target" = cnpg ]; then
  panel_runs+=("$repo/packs/cnpg/dashboards/cnpg.json|||$db_ns")
else
  panels_not_run=$(jq -c '. + [{"dashboard": "cnpg", "reason": "no CloudNativePG in this target"}]' <<<"$panels_not_run")
fi
panel_legit["Replication slots: WAL retained"]="a plain server has no replication slot"
panel_legit["Replication slots: active and inactive time"]="a plain server has no replication slot"
assert_panels
EVIDENCE_EXTRA=$(jq -c --argjson n "$panels_not_run" '.target.dashboards_not_run = $n' <<<"$EVIDENCE_EXTRA")

# the EXIT trap prints the summary line, appends the evidence row and tears down
completed=true
exit 0
