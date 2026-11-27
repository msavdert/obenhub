# A database on a VM or bare metal

The Collector runs on the database host, next to the server, and sends to the
backend of [the guide's index](index.md). Do steps 1 and 2 there first (backend
and monitoring role), and read "What changes on the database".

What is tested: the install test runs the Collector as a container, not as a
host binary, and not against a database on another machine, so this layout is
the documented one with the evidence described on the
[container page](container.md#what-the-install-test-proves-and-what-it-does-not).

## The Collector on the database host

The Collector fragments read their query files from
`/etc/otelcol-contrib/packs/<pack>/`, so the files go there. As root on the
database host, from a checkout of the repository. This is the layout of the
test (collector, host and postgresql packs):

```sh
install -d /etc/otelcol-contrib/packs /etc/otelcol-contrib/tls
cp packs/otelcol-base.yaml /etc/otelcol-contrib/packs/
for p in collector host postgresql; do cp -r "packs/$p" /etc/otelcol-contrib/packs/; done
cp deploy/collector/otelcol-tls.yaml /etc/otelcol-contrib/
cp deploy/collector/obenhub.env.example /etc/otelcol-contrib/obenhub.env
chmod 0600 /etc/otelcol-contrib/obenhub.env
```

Copy `ca.crt`, `client.crt` and `client.key` from `deploy/compose/tls/` of the
backend machine to `/etc/otelcol-contrib/tls/` (never `ca.key`). Then edit
`/etc/otelcol-contrib/obenhub.env`; the test changes these four values and keeps
every other one of the example:

| Variable | Set it to | In the test |
| --- | --- | --- |
| `OBENHUB_GATEWAY_ENDPOINT` | `https://` plus a name given to `tls.sh`, port 4318 | `https://gateway:4318` |
| `OBENHUB_PG_HOST` | the PostgreSQL host the Collector connects to | `pg` |
| `OBENHUB_PG_PASSWORD` | `OTEL_MONITOR_PASSWORD` of step 2 | the generated password |
| `OBENHUB_PG_LOG_GLOB` | where your server writes jsonlog files, or a path that matches nothing | `/nonexistent/postgresql-*.json` (a default server writes no jsonlog) |

The unchanged defaults the test relies on: namespace `obenhub`, collector
instance `otelcol-host-1`, host instance `host-1`, PostgreSQL instance `pg-1` in
cluster `main`, port 5432, user `otel_monitor`, databases `[postgres]`,
`OBENHUB_PG_SSLMODE=disable`. The namespace, the collector instance, the PostgreSQL
instance and the cluster name are the ones `deploy/compose/inventory.yml`
expects (its header says: one host Collector `otelcol-host-1` collecting `pg-1`
of cluster `main`); that file lists what the alerts expect to see, so a
Collector or database you add must be added there too
(`docker compose kill -s SIGHUP vmalert` reloads it). The other variables and
what they mean are in `packs/<pack>/README.md`, "Collector fragment".

Start the Collector with the same version as the gateway image (the `gateway`
service in `deploy/compose/compose.yaml`, `otel/opentelemetry-collector-contrib`
0.165.0 at the time of writing; the file is the authority):

```sh
set -a; . /etc/otelcol-contrib/obenhub.env; set +a
otelcol-contrib \
  --config=/etc/otelcol-contrib/packs/otelcol-base.yaml \
  --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/host/otelcol.yaml \
  --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml \
  --config=/etc/otelcol-contrib/otelcol-tls.yaml
```

The order matters: the TLS overlay comes last. This is `deploy/README.md`,
"Host Collector". The test and `mise run lint:otelcol` run exactly these
arguments in the contrib image, not a host binary; running it as a host binary
or under systemd is unconfirmed (assumption).

Then see [what you should see](index.md#4-what-you-should-see) and, when you are
done, [take it down](index.md#5-take-it-down).
