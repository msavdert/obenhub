# Quick start

From a fresh Debian 13 (amd64) host to an alert that fires and resolves on the
slice1 lab: a PostgreSQL 19 primary and standby, a logical subscriber and
PgBouncer, one OpenTelemetry Collector, and the VictoriaMetrics, VictoriaLogs,
vmalert, Alertmanager and Grafana backend. You break the standby's WAL replay
on purpose, watch `PostgresReplayBacklog` fire, undo the break and watch it
resolve.

You need a user with `sudo` and outbound internet access. The containers'
memory limits add up to about 4.5 GiB (`lab/slice1/compose.yaml`,
`lab/mon/compose.base.yaml`); the smallest host that works is not measured.

Timed on 2026-11-22 on a clean Debian 13.7 VM (4 vCPU, 7 GiB, 40 GB disk),
running these commands as written (Docker 29.10.0, Compose v5.8.0, mise
2026.11.11, obenhub `2eabe0c`); reading and typing time comes on top:

| Step | What | Took |
| --- | --- | --- |
| 1 | Docker Engine and the Compose plugin | 45 s |
| 2, 3 | git, jq, openssl; mise and the repository | 11 s |
| 4 | `mise run --skip-tools lab:up` | 263 s |
| 5 | The scenario, pre-flight included | 214 s |
| | Total | 539 s, about 9 min |

## 1. Docker Engine with the Compose plugin

The commands are those of the
[Docker Engine install guide for Debian](https://docs.docker.com/engine/install/debian/)
(apt repository method, read on 2026-11-21; Debian 13 "Trixie" is listed as
supported):

```sh
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Let your user talk to the Docker daemon without `sudo`
([Linux post-install steps](https://docs.docker.com/engine/install/linux-postinstall/);
the `docker` group is root-equivalent on that host):

```sh
sudo groupadd -f docker
sudo usermod -aG docker "$USER"
```

Log out and back in (or reconnect your SSH session) so that the group applies,
then check:

```sh
docker compose version
docker run --rm hello-world
```

## 2. The tools the scenario script calls

The lab scripts use `git`, `curl`, `jq` (`lab/slice1/scenarios/lib.sh`,
"Needs: docker, curl, jq") and `openssl` (`lab/scripts/gen-env.sh` generates the
passwords with `openssl rand`). `flock` comes with util-linux, which Debian
installs by default (present on the timed run).

```sh
sudo apt install -y git curl jq openssl
```

## 3. mise and the repository

The repository's tasks run through [mise](https://mise.jdx.dev/installing-mise.html)
(official install script, installs to `~/.local/bin/mise`):

```sh
curl -fsSL https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
mise --version
git clone https://github.com/msavdert/obenhub
cd obenhub
```

Do not run `mise install`: every tool `mise.toml` pins is for working on the
repository itself, and slice1 uses none of them. `--skip-tools` keeps `mise run`
from installing them before a task (`mise run --help`).

## 4. Start the lab

```sh
mise run --skip-tools lab:up
```

This is two commands (`[tasks."lab:up"]` in `mise.toml`): generate
`lab/slice1/.env` with random passwords (mode 0600, ignored by git), then
`docker compose -p obenhub-slice1 -f lab/slice1/compose.yaml up -d --wait`. It
pulls the images, builds the PostgreSQL image locally (the pinned `postgres`
image plus pgBackRest from the PGDG apt repository, so the build needs access to
`apt.postgresql.org`), and returns when every healthcheck passes. All ports
listen on `127.0.0.1` only.

Check:

```sh
mise run --skip-tools lab:ps
```

## 5. Fire and resolve an alert

The scenario is `replay-paused`
([`lab/slice1/scenarios/replay-paused.sh`](https://github.com/msavdert/obenhub/blob/main/lab/slice1/scenarios/replay-paused.sh)).
It pauses WAL replay on the standby (`pg_wal_replay_pause()`), writes about
100 MB of WAL on the primary so the standby receives it but does not replay it,
waits until `PostgresReplayBacklog` for `pg-standby` is delivered by
Alertmanager, then resumes replay and waits until the resolved notification is
delivered. It also fails on any alert it did not expect. It can run on a tree
with local changes (the record then says `git_dirty: true`); only a suite
(`mise run lab:scenarios`) needs a clean tree.

Open a second terminal on the host for watching, then start the scenario in the
first:

```sh
mise run --skip-tools lab:scenario replay-paused
```

Before it injects the fault the scenario runs a pre-flight: it reloads the
alerting configuration, waits until Alertmanager holds nothing but `Watchdog`
(up to 300 s), and waits for the lab's first pgBackRest backup (up to 300 s).
On the timed run, right after `lab:up`, it took about 15 s.

### What to expect

`PostgresReplayBacklog` fires about two minutes after the fault (on the timed
run 111.7 s): a backlog above 16 MiB (the lab's override; the pack default is
256 MiB) held for `for: 1m` (`packs/postgresql/rules.yml`), plus scrape and
evaluation every 15 s. After replay resumes it resolves within about a minute
(58.3 s).

The scenario's own output is the primary evidence. Its log lines include
`delivered firing PostgresReplayBacklog:pg-standby at <time>`,
`time to detect <n>s`, `delivered resolved PostgresReplayBacklog:pg-standby at
<time>`, `time to resolve <n>s (from revert)` and
`result appended to lab/slice1/results/runs.jsonl (pass=true)`; it exits 0. On
failure it prints `FAIL replay-paused: ...` and exits 1. It appends one line to
the tracked file `lab/slice1/results/runs.jsonl`.

### Watch it

In the second terminal, the alerts Alertmanager holds as active, the same query
the harness uses to wait for a clean state (`am_active` in
`lab/scenarios/lib-core.sh`). `Watchdog` is always there; `PostgresReplayBacklog:pg-standby`
appears when the alert fires and disappears when it resolves:

```sh
while true; do
  date +%T
  curl -fsS 'http://127.0.0.1:19093/api/v2/alerts?active=true&silenced=false&inhibited=false' \
    | jq -r '.[] | .labels.alertname + (if .labels.service_instance_id then ":" + .labels.service_instance_id else "" end)' | sort
  sleep 5
done
```

Stop it with Ctrl-C. To see both notifications, firing and resolved, as the
harness reads them from VictoriaLogs (the same query fields as `first_record` in
`lab/scenarios/lib-core.sh`):

```sh
curl -fsS 'http://127.0.0.1:19428/select/logsql/query' \
  --data-urlencode 'query=commonLabels.alertname:=PostgresReplayBacklog | sort by (_time) | fields _time,status'
```

The ports, all on `127.0.0.1`: Alertmanager 19093, vmalert 18880
(`http://127.0.0.1:18880/vmalert/` lists rules and their state; path not
checked), VictoriaMetrics 18428, VictoriaLogs 19428, Grafana 13000. For a
browser on your own machine, forward them over SSH, for example
`ssh -L 13000:127.0.0.1:13000 -L 19093:127.0.0.1:19093 <host>`. Grafana's user is
`admin`; the password is `GRAFANA_ADMIN_PASSWORD` in `lab/slice1/.env`. The
dashboard "PostgreSQL slice 1" shows the standby's replication state; what the
alert means and what to look at first is in the
[runbook](../runbooks/postgresql.md#postgresreplaybacklog).

## 6. Stop the lab

```sh
mise run --skip-tools lab:down
```

This runs `docker compose -p obenhub-slice1 -f lab/slice1/compose.yaml down -v`
and deletes the lab's volumes. `lab/slice1/.env` stays, so the next `lab:up`
keeps the same passwords.

## If something fails

- `permission denied` on the Docker socket: the group change in step 1 has not
  reached this shell; log in again.
- `refusing to start replay-paused: another lab run holds ...`: another
  scenario or suite is running on this host; one run at a time.
- `FAIL replay-paused: precondition: ...`: the message names what was not ready
  (Alertmanager not clean, replication not streaming, no backup yet). Wait a
  minute and run it again, or `mise run --skip-tools lab:ps` to see which
  container is not healthy.
- Anything left over after a killed run: `mise run --skip-tools lab:down`, then
  `mise run --skip-tools lab:up`.

## Next

- [Monitor what you already run](monitor/index.md): the backend and a Collector
  against your own PostgreSQL, without the lab.
- The other 26 slice1 scenarios: `ls lab/slice1/scenarios`, run with
  `mise run --skip-tools lab:scenario <name>`.
