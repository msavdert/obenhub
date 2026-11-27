# A PostgreSQL container

The Collector runs as a container next to a PostgreSQL container and sends to
the backend of [the guide's index](index.md). Do steps 1 and 2 there first
(backend and monitoring role) and read "What changes on the database". This
page is written from
[`deploy/test/install-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/install-test.sh),
which runs this layout; where the test differs from what you would run, the
text says so.

## What the install test proves, and what it does not

The latest run (2026-11-27, commit 0abd499, clean tree, line in
`deploy/results/runs.jsonl`) passed in 1207 s against a plain `postgres:18.7`
container with default settings: the heartbeat of the database was in
VictoriaMetrics, nothing but `Watchdog` fired after a 1020 s settle, the
dead-man receiver got `Watchdog` every 60 s, the Collector's secrets were mode
600, and 33 dashboard panels had data
(19 are empty by design, 2 replication slot panels are accepted empty because a
plain server has none). It does not exercise journald or PostgreSQL log
collection (the [VM page](vm.md) has the first for the Collector's own unit), a
Collector running as a host binary (this test runs the Collector image in a
container, as `mise run lint:otelcol` does; `mise run deploy:vm-test` runs the
binary), a database on another machine, or any pack but collector, host and
postgresql.

## The flow

Run it from the repository root once the backend of step 1 of the
[index](index.md) is up; step 2 (the role) is done inside the PostgreSQL
container below. One change to step 1: the Collector container reaches the gateway as `gateway`, the
network alias of the gateway service, so `gateway` must be one of the names the
gateway certificate carries. `tls.sh` takes several names and writes all of them
into the certificate (`deploy/compose/tls.sh` header: `tls.sh <gateway DNS name
or IP> [<more names or IPs>...]`, SAN = the names and IPs given). The test
gives only `gateway`; with a name for other machines as well:

```sh
cd deploy/compose
bash tls.sh gateway.example.net gateway
```

Without `gateway` among the names the client rejects the gateway's certificate
(`x509`) and no metric arrives. `tls.sh` keeps files that exist (its header: to
re-issue, delete the file), so if you ran it before without that name, delete
`tls/gateway.crt` and `tls/gateway.key`, run it again and restart the gateway
container (the restart is an assumption: the gateway reads the files at start).

Then the PostgreSQL container, the role and the Collector. The images are the
test's: `PG_IMAGE` is the pin of
[`deploy/test/install-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/install-test.sh)
line 48, the Collector image is the one of the `gateway` service in
`deploy/compose/compose.yaml` (line 20), read with the test's own `sed`. Your
PostgreSQL container exists already: skip the first two commands, and use its
network and its name as `OBENHUB_PG_HOST`.

```sh
PG_IMAGE=postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
OTELCOL_IMAGE="$(sed -n '/^  gateway:/,/^  victoriametrics:/s/^    image: *\(\S*\).*/\1/p' deploy/compose/compose.yaml)"

docker network create pgnet
docker run -d --name pg --network pgnet --network-alias pg \
  -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" "$PG_IMAGE"
# the image's init scripts restart the server once: wait, pause, wait again
for _ in $(seq 60); do docker exec pg pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
sleep 3
for _ in $(seq 60); do docker exec pg pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done

# step 2 of the index, with psql inside the server container
export OTEL_MONITOR_PASSWORD="$(openssl rand -hex 12)"
docker exec -i -e OTEL_MONITOR_PASSWORD pg psql -U postgres -v ON_ERROR_STOP=1 -q \
  -c '\getenv mon_pw OTEL_MONITOR_PASSWORD' -f - < packs/postgresql/monitoring-role.sql
```

The Collector's configuration directory has the layout of
[the VM page](vm.md#3-the-files-of-the-packs), built in a scratch
directory `$oc` and with four values of [its table](vm.md#4-the-environment-file)
(gateway endpoint, PostgreSQL host, password and log glob; the port stays 5432)
set the way the test sets them. The container reads a Docker env file, and `docker --env-file` keeps the
single quotes that a shell would strip (the example has
`OBENHUB_PG_DATABASES='[postgres]'`), so the test removes them:

```sh
oc="$(mktemp -d)"
install -d "$oc/packs" "$oc/tls"
cp packs/otelcol-base.yaml "$oc/packs/"
for p in collector host postgresql; do cp -r "packs/$p" "$oc/packs/"; done
cp deploy/collector/otelcol-tls.yaml "$oc/"
cp deploy/collector/obenhub.env.example "$oc/obenhub.env"
cp deploy/compose/tls/ca.crt deploy/compose/tls/client.crt deploy/compose/tls/client.key "$oc/tls/"
chmod 0600 "$oc/obenhub.env"
sed -i -e "s#^OBENHUB_GATEWAY_ENDPOINT=.*#OBENHUB_GATEWAY_ENDPOINT=https://gateway:4318#" \
  -e "s#^OBENHUB_PG_HOST=.*#OBENHUB_PG_HOST=pg#" \
  -e "s#^OBENHUB_PG_PASSWORD=.*#OBENHUB_PG_PASSWORD=$OTEL_MONITOR_PASSWORD#" \
  -e "s#^OBENHUB_PG_LOG_GLOB=.*#OBENHUB_PG_LOG_GLOB=/nonexistent/postgresql-*.json#" "$oc/obenhub.env"
(umask 077; sed -n "s/^\([A-Z_0-9]*\)='\(.*\)'$/\1=\2/p;t;/^[A-Z_0-9]*=/p" "$oc/obenhub.env" > "$oc/docker.env")
```

Two things in this layout differ from a host, and the test handles both with
one overlay file that it writes next to the configuration (it is not a file of
the repository; the heredoc `install-test-overlay.yaml` of `deploy/test/install-test.sh` is the source
of the text below):

- The Collector image has no `journalctl`, so the journald receivers of the
  host pack cannot read anything. The overlay replaces the receivers of the host
  logs pipeline by the base's `nop` (a list is replaced on merge; the pack files
  stay untouched). In this layout the journald receiver is turned off, so the
  journal is not collected and the host dashboard's log panels stay empty.
- In a container the filesystem scraper reports nothing without a `root_path`
  (measured by the test with 0.165.0: 0 data points and a warning). The overlay
  sets `root_path` of the host pack's receiver to `/hostfs`, and the host's `/`
  is mounted there read-only, as the upstream hostmetrics receiver README
  describes for containers. The host pack does not set `root_path` itself. The
  whole `/` is mounted, not just `/proc`: the scraper reads the mount list from
  `<root_path>/proc` and calls statfs on `<root_path><mountpoint>`.

```sh
cat > "$oc/install-test-overlay.yaml" <<'YAML'
receivers:
  host_metrics/obenhub-host:
    root_path: /hostfs
service:
  pipelines:
    logs/obenhub-host:
      receivers: [nop]
YAML
docker run -d --name otelcol --network pgnet --user "$(id -u):$(id -g)" --env-file "$oc/docker.env" \
  --tmpfs /var/lib/otelcol-contrib:mode=1777 -v "$oc:/etc/otelcol-contrib:ro" -v /:/hostfs:ro "$OTELCOL_IMAGE" \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml \
  --config=/etc/otelcol-contrib/install-test-overlay.yaml
docker network connect obenhub_mon otelcol
```

`obenhub_mon` is the network of the backend's Compose project (`<project>_mon`;
the project is named `obenhub` by `name:` in `deploy/compose/compose.yaml`, line 16);
it makes the name `gateway` resolve for the
Collector. With the backend on another machine, `OBENHUB_GATEWAY_ENDPOINT` is a
name or address given to `tls.sh` and nothing is connected.

What still differs from the test, all of it naming only:

- The test names its network, containers and Compose project
  `obenhub-install-test-*`, moves the backend's ports to 61000 and up, and
  gives `tls.sh` only `gateway`.
- `--user` and the `tmpfs` are the test's: the container runs as the user who
  owns the files, so `obenhub.env`, `docker.env` and `client.key` stay readable
  by that user only (mode 0600), and `/var/lib/otelcol-contrib` (the default
  `OBENHUB_STORAGE_DIR` of the example is below it) is a tmpfs, so the
  checkpoints of the log reader do not survive a restart. For a real install
  give the storage directory a volume (assumption, not tested).

Then see [what you should see](index.md#4-what-you-should-see) and, when you
are done, [take it down](index.md#5-take-it-down). The test also removes what
this page created:

```sh
docker rm -f otelcol pg
docker network rm pgnet
rm -rf "${oc:?}"
```

## What the test cleans up and what you keep

The test builds everything in a temporary directory and removes it, the
containers and the network on exit; you are installing for real, so
`deploy/compose/tls/` and `.env` stay. The certificates are modelled on the
labs' PKI with lifetimes chosen by the author (CA 10 years, leaf 2 years, an
assumption recorded in `deploy/compose/tls.sh`); keep `ca.key` off the database
hosts.

## Run the test yourself

```sh
mise run --skip-tools deploy:install-test
```

Needs Docker, `jq`, `curl` and `openssl`, takes about 15 minutes and is not part
of `mise run check`. It appends a line to `deploy/results/runs.jsonl` and prints
a final `install-test: PASS in <n>s, ...` line; set `INSTALL_TEST_EVIDENCE=0` to
skip the line.
