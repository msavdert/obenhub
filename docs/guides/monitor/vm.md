# A database on a VM or bare metal

The Collector runs on the database host, next to the server, as the upstream
`otelcol-contrib` package under systemd, and sends to the backend of
[the guide's index](index.md). Do steps 1 and 2 there first (backend and
monitoring role), and read "What changes on the database". This page is
written from
[`deploy/test/vm-test.sh`](https://github.com/msavdert/obenhub/blob/main/deploy/test/vm-test.sh),
which runs these steps on a second machine; where the test differs from what you
would run, the text says so.

## What the VM test proves, and what it does not

`deploy/results/runs.jsonl` holds the lines of the runs on a committed tree
(`"test": "vm-test"`). The run of 2026-11-27 on commit 71da319 plus the then
uncommitted test files (its line was not kept, because `git_dirty` was true)
passed in 1164 s. Backend: this machine (Docker). Target: a second machine, Debian 13
amd64, PostgreSQL 18.7 from PGDG with a fresh cluster made by `pg_createcluster`,
the Collector 0.165.0 from the upstream `.deb` under the package's unit. After a
1020 s settle the heartbeat of the database was in VictoriaMetrics, nothing but
`Watchdog` fired and nothing was pending, `CollectorAbsent` of the host Collector
had fired once and stopped 20 s after the start (the 120 s grace the container
test also allows), the dead-man receiver got `Watchdog` six times 60 s apart,
systemd had not restarted the unit (`NRestarts` 0), `journalctl` held no line
with "error" since that start (the test prints this count and records it in the
line as `collector_log_error_lines`; it does not assert it), VictoriaLogs held 3 journal records of
`otelcol-contrib.service`, and 37 dashboard panels had data (15 are empty by
design, 2 replication slot panels are accepted empty because a default server has
none). The four "Statements" panels have data because the test enables
`pg_stat_statements`. The host dashboard has data from the real machine: the
Collector runs on the host itself, so there is no `root_path` overlay and no
journald stub, which the container test needs.

What the test does not exercise:

- PostgreSQL log collection: a default Debian cluster writes plain stderr lines,
  not jsonlog, so `OBENHUB_PG_LOG_GLOB` matches nothing.
- The journal of anything but the Collector's own unit, and the kernel records
  (the receivers are loaded; the test asserts the first only). What happens
  without `SupplementaryGroups=systemd-journal`, or without `StateDirectory=`,
  was not run.
- RPM-based hosts, other Debian or Ubuntu releases, arm64, a proxy or firewall
  between the host and the gateway (the two machines share one network), a
  server on a third machine (the Collector connects to `127.0.0.1`), and
  `sslmode` other than `disable`.
- Upgrading the package: the test edits the conffile `otelcol-contrib.conf`, so
  `dpkg` asks about it on an upgrade (assumption, from how dpkg treats modified
  conffiles; not run).
- The packs `pgbouncer`, `patroni`, `etcd` and `pgbackrest`.
- The release's sigstore signatures; only the `.sha256` is checked.

## What the host needs

- Debian or Ubuntu with systemd, `apt`, `curl` and root (the test ran Debian 13).
  The release also has an `.rpm` and a `.tar.gz`; they are not tested here
  (assumption: the same files and unit work).
- A PostgreSQL the Collector can log in to over TCP. The test builds one the way
  Debian's `postgresql-common` does, with its defaults and nothing else changed:

  ```sh
  pg_createcluster 18 vmtest --port 5433 --start
  ```

  The cluster name has no dash: `postgresql@.service` of Debian builds the path of
  its configuration from `%I`, and its own comment says "%I breaks for cluster
  names containing dashes" (a cluster called `obenhub-test` did not start in the
  first attempt on the target, `AssertPathExists=/etc/postgresql/18/obenhub/test/postgresql.conf`
  was not met). Two defaults of that cluster are what the guide's table asks for
  ("A `pg_hba.conf` entry ... and a `listen_addresses`"), and the test reads
  both and fails when they are not there: the rule
  `host all all 127.0.0.1/32 scram-sha-256` in
  `/etc/postgresql/18/vmtest/pg_hba.conf` (the stock file; `pg_createcluster` runs `initdb --auth-local peer
  --auth-host scram-sha-256`, a line the test prints from its output), and
  `listen_addresses` still at its default `localhost` (`pg_settings.source` is
  `default`). The Collector therefore connects to `127.0.0.1`, not to the
  socket. A server that listens elsewhere or has no such rule needs the entry of
  the table.
- The role of step 2 of the index, made on Debian as the `postgres` user through
  the local socket (port 5433 here). The test passes the password on standard
  input, so it is in no command line; `--preserve-env` hands it to `psql`:

  ```sh
  export OTEL_MONITOR_PASSWORD="$(openssl rand -hex 12)"
  sudo --preserve-env=OTEL_MONITOR_PASSWORD -u postgres psql -p 5433 -v ON_ERROR_STOP=1 -q \
    -c '\getenv mon_pw OTEL_MONITOR_PASSWORD' -f /tmp/obenhub-vm-test/packs/postgresql/monitoring-role.sql
  ```

  The file is in the copy of step 1, so the test copies the files first and makes
  the role after; `postgres` must be able to read it. The test then logs in as
  `otel_monitor` over `127.0.0.1:5433` with that password (`psql -h 127.0.0.1`)
  and fails if that does not work.

- `pg_stat_statements`, so the four "Statements" panels have data. The test does
  what the table says: a file `/etc/postgresql/18/vmtest/conf.d/obenhub.conf`
  with `shared_preload_libraries = 'pg_stat_statements'` (Debian's
  `postgresql.conf` includes `conf.d`), a restart of the cluster
  (`pg_ctlcluster 18 vmtest restart`) and `CREATE EXTENSION pg_stat_statements`
  in database `postgres`. The files of the extension come with Debian's
  `postgresql-18` package (`dpkg -S` on the target). Skip it and those panels stay empty (the index says
  so).
- The gateway of step 1 reachable from the host on its port, with a certificate
  that names the address the host uses: the test gives `tls.sh` the backend's IP
  address (`bash tls.sh 10.0.0.11`, the address the test machine has) and binds
  the gateway to that address.

## 1. Copy the files to the host

From the checkout of the repository on the machine that holds the backend (the
test streams them with `tar` over `ssh`; `dbhost` is your database host):

```sh
ssh dbhost 'mkdir -p /tmp/obenhub-vm-test/tls'
tar -cf - packs/otelcol-base.yaml packs/collector packs/host packs/postgresql deploy/collector \
  | ssh dbhost 'tar -C /tmp/obenhub-vm-test -xf -'
tar -C deploy/compose/tls -cf - ca.crt client.crt client.key | ssh dbhost 'tar -C /tmp/obenhub-vm-test/tls -xf -'
```

The three files are named one by one: `ca.key` never leaves the backend machine.
The rest of this page runs on the database host, as root, in `/tmp/obenhub-vm-test`.

## 2. The package

The Collector is the version of the gateway image (the `gateway` service in
`deploy/compose/compose.yaml`: `otel/opentelemetry-collector-contrib` 0.165.0 at
the time of writing; the file is the authority). Download the package of that
release, check it against the checksum the release publishes, and install it
with `apt`:

```sh
v=0.165.0
deb="otelcol-contrib_${v}_linux_$(dpkg --print-architecture).deb"
url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$v"
curl -fsSLO "$url/$deb" && curl -fsSLO "$url/$deb.sha256"
echo "$(awk '{print $1}' "$deb.sha256")  $deb" | sha256sum -c -
apt-get install -y "./$deb"
```

The release has no combined checksums file: each asset has a `<name>.sha256`
next to it that holds the hash alone (the listing of v0.165.0 was read on
2026-11-27, and the hash of the amd64 package it gave matched `sha256sum` of the
download). The `.sigstore.json` files of the release are not checked.

What the package does (read from the `.deb` of 0.165.0 with `dpkg-deb`, and
from the target with `systemctl cat`):

- `/usr/bin/otelcol-contrib`, the unit `/lib/systemd/system/otelcol-contrib.service`
  (Debian shows it under `/usr/lib/systemd/system/`) and two configuration files
  that `DEBIAN/conffiles` lists: `/etc/otelcol-contrib/config.yaml` (a sample)
  and `/etc/otelcol-contrib/otelcol-contrib.conf`.
- The unit runs as `User=otelcol-contrib`, `Group=otelcol-contrib`, takes its
  environment from `EnvironmentFile=/etc/otelcol-contrib/otelcol-contrib.conf`
  and starts `/usr/bin/otelcol-contrib $OTELCOL_OPTIONS`. The conffile sets
  `OTELCOL_OPTIONS="--config=/etc/otelcol-contrib/config.yaml"`. The hardening
  it carries is `NoNewPrivileges`, `LockPersonality`, `RestrictRealtime`,
  `RestrictSUIDSGID` and the `Protect*` options for control groups, kernel
  modules, kernel tunables and hostname; there is no `ProtectSystem`, so the
  service user reads what the files' modes allow.
- `DEBIAN/preinst` creates the system user and group `otelcol-contrib` when
  they are missing (`useradd --system --user-group --no-create-home --shell
  /sbin/nologin`) and the package never removes them. `DEBIAN/postinst` enables
  the unit and restarts it because `config.yaml` exists, so the Collector runs
  with the **sample configuration** until step 6: it listens on all addresses
  (OTLP on 4317 and 4318, Jaeger, Zipkin, pprof on 1777, zpages on 55679) and
  only logs what it receives (the `debug` exporter). Nothing of obenhub is in it.

## 3. The files of the packs

```sh
cd /tmp/obenhub-vm-test
install -d /etc/otelcol-contrib/packs /etc/otelcol-contrib/tls
cp packs/otelcol-base.yaml /etc/otelcol-contrib/packs/
for p in collector host postgresql; do cp -r "packs/$p" /etc/otelcol-contrib/packs/; done   # plus pgbouncer, patroni, etcd, pgbackrest if used
cp deploy/collector/otelcol-tls.yaml /etc/otelcol-contrib/
cp deploy/collector/obenhub.env.example /etc/otelcol-contrib/obenhub.env
chmod 0600 /etc/otelcol-contrib/obenhub.env
cp tls/ca.crt tls/client.crt tls/client.key /etc/otelcol-contrib/tls/
```

The Collector fragments read their query files from
`/etc/otelcol-contrib/packs/<pack>/`, so the files go there. The service user
is not root and must read the client key, and nobody else should:

```sh
chgrp -R otelcol-contrib /etc/otelcol-contrib/tls
chmod 0750 /etc/otelcol-contrib/tls
chmod 0644 /etc/otelcol-contrib/tls/ca.crt /etc/otelcol-contrib/tls/client.crt
chmod 0640 /etc/otelcol-contrib/tls/client.key
```

`obenhub.env` stays `0600 root`: systemd reads `EnvironmentFile=` as root, so
the service user never needs to read it (it holds the monitoring password).

## 4. The environment file

Edit `/etc/otelcol-contrib/obenhub.env`. The test changes these five values
(with a `sed` script on standard input, so the password is in no command line)
and keeps every other one of the example:

| Variable | Set it to | In the test |
| --- | --- | --- |
| `OBENHUB_GATEWAY_ENDPOINT` | `https://` plus an address given to `tls.sh`, and the gateway port | `https://10.0.0.11:61105` |
| `OBENHUB_PG_HOST` | the PostgreSQL host the Collector connects to | `127.0.0.1` |
| `OBENHUB_PG_PORT` | its port | `5433` |
| `OBENHUB_PG_PASSWORD` | `OTEL_MONITOR_PASSWORD` of step 2 | the generated password |
| `OBENHUB_PG_LOG_GLOB` | where your server writes jsonlog files, or a path that matches nothing | `/nonexistent/postgresql-*.json` |

A default Debian cluster writes plain stderr lines to
`/var/log/postgresql/postgresql-18-vmtest.log` (`log_destination` is `stderr`,
`pg_lsclusters` shows the file), not jsonlog, so the test collects no
PostgreSQL log; see "What changes on the database" for what jsonlog needs.

The unchanged defaults the test relies on: namespace `obenhub`, collector
instance `otelcol-host-1`, host instance `host-1`, PostgreSQL instance `pg-1` in
cluster `main`, user `otel_monitor`, databases `[postgres]`,
`OBENHUB_PG_SSLMODE=disable`, the journal units `[postgresql, otelcol-contrib]`
and the storage directory `/var/lib/otelcol-contrib/obenhub`. The namespace, the
collector instance, the PostgreSQL instance and the cluster name are the ones
`deploy/compose/inventory.yml` expects (its header says: one host Collector
`otelcol-host-1` collecting `pg-1` of cluster `main`); that file lists what the
alerts expect to see, so a Collector or database you add must be added there too
(`docker compose kill -s SIGHUP vmalert` reloads it). The other variables and
what they mean are in `packs/<pack>/README.md`, "Collector fragment".

## 5. The unit

No unit of our own: the package's takes the `--config` arguments from its
`OTELCOL_OPTIONS` and the obenhub variables from a drop-in. The order matters
(the TLS overlay comes last, because it replaces the self-telemetry reader of the
collector pack; add the `otelcol.yaml` of `pgbouncer`, `patroni`, `etcd` or
`pgbackrest` before it). This is `deploy/README.md`, "Host Collector", as
options of the service:

```sh
sed -i 's#^OTELCOL_OPTIONS=.*#OTELCOL_OPTIONS="--config=/etc/otelcol-contrib/packs/otelcol-base.yaml --config=/etc/otelcol-contrib/packs/collector/otelcol.yaml --config=/etc/otelcol-contrib/packs/host/otelcol.yaml --config=/etc/otelcol-contrib/packs/postgresql/otelcol.yaml --config=/etc/otelcol-contrib/otelcol-tls.yaml"#' \
  /etc/otelcol-contrib/otelcol-contrib.conf
install -d /etc/systemd/system/otelcol-contrib.service.d
cat >/etc/systemd/system/otelcol-contrib.service.d/obenhub.conf <<'UNIT'
[Service]
EnvironmentFile=/etc/otelcol-contrib/obenhub.env
StateDirectory=otelcol-contrib
SupplementaryGroups=systemd-journal
UNIT
systemctl daemon-reload
```

The drop-in adds to the unit, it does not replace it (a second
`EnvironmentFile=` is read after the first):

- `EnvironmentFile=` the obenhub variables. systemd keeps the quotes of the
  example's two list values out of the value, as the test's run shows (the
  `[postgresql, otelcol-contrib]` journal list was accepted by the Collector).
- `StateDirectory=otelcol-contrib` makes `/var/lib/otelcol-contrib` owned by the
  service user. The base pack's file storage writes under
  `OBENHUB_STORAGE_DIR` (`/var/lib/otelcol-contrib/obenhub`, `create_directory:
  true`), and the package does not create `/var/lib/otelcol-contrib`; without the
  directive the service user could not create it under the root-owned `/var/lib`
  (reasoning, not run).
- `SupplementaryGroups=systemd-journal` lets the service user read the journal for
  the host pack's two `journald` receivers (units and kernel). The Oracle lab does
  the same (`lab/oracle/README.md`). The test shows that journal records of
  `otelcol-contrib.service` arrive; what happens without the group was not run
  (assumption: the receivers get nothing).

## 6. Start it and look

```sh
systemctl restart otelcol-contrib
systemctl status otelcol-contrib
```

Then see [what you should see](index.md#4-what-you-should-see). The test also
reads the unit's `NRestarts` (it must be 0), counts the lines with "error" in the journal of this start of the unit
(`journalctl _SYSTEMD_INVOCATION_ID=...`; printed and recorded, not asserted) and
asks VictoriaLogs for the journal records of the Collector's own unit:

```sh
curl -fsS http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode 'query=service.name:host service.instance.id:host-1 journald._SYSTEMD_UNIT:otelcol-contrib.service _time:30m | stats count() c'
```

The form is the one `lab/oracle/README.md` uses for the same field names.

## What the test cleans up and what you keep

On exit the test stops the unit, runs `apt-get purge otelcol-contrib` (which
removes the two conffiles), removes `/etc/otelcol-contrib`,
`/var/lib/otelcol-contrib` and the drop-in directory, deletes the user and group
the package created, drops the cluster with `pg_dropcluster --stop 18 vmtest`,
removes `/tmp/obenhub-vm-test` and takes the compose project down. You are
installing for real, so you keep all of that; to stop the Collector on the
host: `systemctl disable --now otelcol-contrib`, and drop the `otel_monitor` role
if you want it gone.

## Run the test yourself

```sh
mise run --skip-tools deploy:vm-test
```

Without `--force` it refuses a target with leftovers (below); add `-- --force`
only after reading what it would move aside.

Needs Docker, `jq`, `curl`, `openssl` and `ssh` on the machine that runs it, and
an ssh target (`VM_TEST_TARGET`, default `pg-lab`) that is Debian or Ubuntu with
passwordless `sudo`, `postgresql-18` and `postgresql-common`, and that can reach
this machine on the gateway port at `VM_TEST_ADDR` (default `10.0.0.11`, the
address that goes into the certificate). It takes about 20 minutes and is not
part of `mise run check`. It appends a line with `"test": "vm-test"` to
`deploy/results/runs.jsonl` and prints a final `vm-test: PASS in <n>s, ...` line;
set `VM_TEST_EVIDENCE=0` to skip the line. Before it changes anything on the
target it checks, read-only, and refuses (exit 2, no line) when the target
already has a cluster `18/vmtest` or `/etc/postgresql/18/vmtest`, a package
`otelcol-contrib`, a listener on port 5433, `/tmp/obenhub-vm-test`, or a
`<path>.vm-test-aside` of an earlier run; none of these is ever forced or
touched. A `/etc/otelcol-contrib`, `/var/lib/otelcol-contrib` or drop-in
directory that is there also refuses, unless `--force`: the test then moves it
to `<path>.vm-test-aside` and moves it back on exit (and fails the run, leaving
the aside, if the path exists again by then). A failed teardown fails the run
and its line.
