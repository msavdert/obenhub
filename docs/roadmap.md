# Roadmap

The only place for plans, open items only: what runs is described in
`lab/README.md` and each lab's README. Scope and order are
decided in [ADR 0001](adr/0001-goal-and-scope.md).

## Next

Every lab has a full suite recorded on `main`; the evidence is in each lab's
`results/runs.jsonl` and `scripts/check-evidence.sh --strict <lab>` verifies
it (`--full` for a release). The order below was decided by the owner on
2026-11-19 after a review of release 0.17.0 (`9aa8c51`) and replaces the
order of 2026-11-12: the packs leave the lab before PostgreSQL 19 arrives.
Each item names the files it starts from and a criterion that is checked by
running something. Items marked "by reading" were found in the source and
are reproduced by a test before they are fixed. Within phases B and C the
items land back to back and share one full suite chain, which also carries
the held dependency update batch and closes a release.

### A. Tooling and documents, no lab run

- [ ] A1 rest: `lab/scenarios/run-suite.sh` refuses scenario timing
      overrides (`CONTROL_SECONDS`, the `lib-core.sh` windows) from the
      environment. Done on branch `fix/suite-timing-refusal` with its test in
      `lab:guard-test`; it changes the shared harness, which maps to a full
      suite in every lab, so it lands at the start of the B+C chain
- [x] A2 Affected-scenario mapping (`scripts/affected-scenarios.sh`,
      `scripts/evidence-paths.sh` and the test), before any pack edit. Today
      one changed alert in a pack reruns every scenario of every lab that
      uses the pack (about 7 h for the `postgresql` pack), and a changed
      shared Patroni scenario maps to all scenarios of all five labs (by
      reading: `links()` keeps only targets under the lab's own
      `scenarios/`). Wanted: a changed alert maps to the scenarios whose
      `EXPECT` or `ALLOW` name it, plus `control`; a shared Patroni scenario
      maps to its linked scenario in stage3 and pgha and to nothing
      elsewhere; comment-only and annotation-only changes, `versions.sh` and
      `upstream-receiver-metrics.txt` map to nothing (`versions.sh` to ALL under `--full`); a Grafana-only change
      maps to `lab:<lab>:panels`; a test derives the cross-lab mounts from
      the Compose files and compares them with `evidence_extra_paths`. Done
      when `mise run lab:affected-test` has a case for each
- [x] A3 Documents that drifted: site navigation, `README.md`, the plans in
      ADR 0002, the etcd version, the pgha `leader-killed` outcomes, the
      oracle suite of record, the k8s tool versions in its README (the
      `mise.k8s.toml` comment moved to A4) and the pgha load rate
      comment. `mise run docs:nav-check` now fails on a page missing from the
      navigation (`zensical build --strict` does not)
- [ ] A4 Renovate raised `kubectl` to 1.37.2 against a 1.36.4 kind node
      although `renovate.json` means to hold minors back. Assumption to
      confirm in the Renovate documentation: the mise manager matches on
      `matchDepNames`, not `matchPackageNames`. The comment above `kubectl` in
      `mise.k8s.toml` still names 1.36.6; it is fixed with this item, since
      `affected-scenarios.sh` sees comment-only changes in YAML and shell
      only and maps that file to the full k8s suite
- [x] A5 `release-evidence` as a required check on `main` (owner,
      2026-11-19; the ruleset requires it next to `check` and
      `semantic-title`)
- [ ] A6 `lab/obi` and `lab/overhead` reduced to their results pages and
      scripts (`results/cells`, `contaminated-2026-11-06`,
      `2026-11-07-old-pack`)

### B. Defects that need lab runs

- [ ] B1 Oracle. `OraclePrimaryChanged` also fires when a primary is
      demoted: the role is an attribute of `oracledb.database.primary`, and
      the `fsfo-failover` record of suite `oracle-20261118T202631Z-37e22f2`
      shows a firing at the reinstate, without a promotion.
      `oracledb.backup.failed` counts a database backup for one kind where
      `oracledb.backup.age` counts it for both, and has no tie-breaker
      (`lab/packs/oracledb-backup/queries.yaml`). The inventory has no
      gateway and no `obenhub.upstream`
      (`lab/oracle/mon/vmalert/inventory.yml`). The `sql_query` receivers in
      `lab/oracle/files/otelcol-obs.yaml` set no `max_open_conn` (ADR 0003).
      The account query matches only `C##OBENHUB\_%`. Done when a unit test
      covers a demotion without a promotion and the backup kinds, and the
      oracle suite passes
- [ ] B2 PostgreSQL and Kubernetes rules. The logical-replication rules in
      `lab/slice1/vmalert/rules/postgresql.yml` use `increase()` without
      the counter-start handling the pack documents
      (`lab/packs/postgresql/rules.yml`, `PostgresDeadlocks`); fixed as they
      move into the pack (C2). `KubernetesNodeNotReady` carries no
      `service.instance.id`, so the scenario cannot tell which node fired.
      stage3, pgha and k8s give the `postgresql` receiver only the database
      `postgres` while the load runs in `app`
- [ ] B3 Harness (`lab/scenarios/lib-core.sh`, `run-suite.sh`, each lab's
      `lib.sh`). The precondition fails when the running image IDs differ
      from the Compose file, and the record carries the running IDs (slice1,
      stage3 and k8s record what the files say today); one unexpected-alert
      window over the whole suite (an alert between two scenarios falls in
      none today); `control` proves that the Alertmanager sink and the
      PostgreSQL log path were alive; a resolution is searched from
      detection, not only after the revert. Done when a guard test covers
      each, then every lab's suite
- [ ] B4 slice1 Alertmanager: `lab/mon/alertmanager.yml` says inhibit rules
      race with delivery, `lab/slice1/alertmanager/alertmanager.yml` still
      has five. One of the two changes

### C. Packs usable outside the lab

- [ ] C1 `lab/packs` moves to `packs/`, paths only (scripts, `mise.toml`,
      lab mounts, tests, generated reference). Done when `git grep
      lab/packs` is empty and `mise run check` passes
- [ ] C2 What the labs still keep moves into packs: the
      logical-replication rules, a `pgbouncer` pack, the PostgreSQL, Patroni
      and CloudNativePG dashboards, and one monitoring-role SQL file that
      all four PostgreSQL labs use (five copies today)
- [ ] C3 Identity, with an amendment to ADR 0006 first. Every join in the
      `postgresql` pack is on `service.instance.id` alone (13 places), so
      two clusters with a `pg-1` in one backend break the rules, and a
      recreated pod has two series for a few minutes. `obenhub.cluster.name`
      becomes mandatory, joins use cluster, instance and pod UID where
      present, the backend-wide guards (`PostgresStandbyNotStreaming`, the
      etcd member count) become per cluster, and a rule fires on a target
      without a cluster. Done when unit tests with two clusters sharing an
      instance name, and with two pod UIDs for one instance, pass
- [ ] C4 Thresholds: a production default in the rule and an optional
      override series, in one form everywhere, as `lab/packs/etcd/rules.yml`
      does since #113. About 30 literal values in the postgresql, patroni,
      oracledb-dg, host and etcd packs; the labs keep today's values as
      overrides in their inventories; dashboards read the same series; each
      pack README gets a generated threshold table. The owner sets each
      production value. Done when every pack has a defaults test and an
      override test
- [ ] C5 Collection interval: the rules assume 15 s (windows of 30 s in 17
      places, which cannot hold at 60 s). Stated in each pack README, and a
      rule fires when heartbeat samples are more than 30 s apart
- [ ] C6 `description` and `runbook_url` on every alert (82 today, none has
      either), a runbook page only for alerts a scenario fires, with the
      SQL or LogsQL to look at first; a lint fails without both
- [ ] C7 One complete Collector fragment per pack, checked by
      `lint:otelcol`, and inventories generated from a target list,
      byte-equal to the hand-written ones

### D. Install path

- [ ] D1 `deploy/compose`: the backend and gateway of `lab/mon` on their
      own; Collector configuration for a host and values for the upstream
      Helm chart; an Alertmanager example that routes by severity and has a
      dead-man route for `Watchdog`
- [ ] D2 An install test without lab files: a plain PostgreSQL container
      and D1 with production defaults; the heartbeat is there, nothing but
      `Watchdog` fires, the dashboard panels have data
- [ ] D3 Quick start on slice1 and the install guide: a stranger reaches a
      fired and resolved alert in under 15 minutes, timed on a clean VM.
      These are the first Guides pages on the docs site; further Learn
      pages follow, each for a scenario that runs
- [ ] D4 pgha and oracle read their addresses from an untracked file
      (`lab/pgha/nodes.sh`, `lab/oracle/gateway.sh` and `pair.sh` hold the
      owner's today), so that the labs run elsewhere on a clean tree

### E. PostgreSQL versions

- [ ] E1 The pack's queries run against a throwaway container of every
      supported major in `mise run check`, and a generated diff lists the
      views and columns the packs read that changed between two versions
      of an engine (PostgreSQL majors; Oracle release updates and 19c
      against 26ai), run when Renovate or the EOL check brings a new
      version. Queries carry the versions they support
- [ ] E2 PostgreSQL 19 as the major slice1 runs its suite on, once the
      `postgresql` receiver, pgBackRest and the official image support it
      (not checked yet). The full suite runs on one major; the other
      supported majors are covered by E1
- [ ] E3 The one query that needs PostgreSQL 18
      (`pg_stat_subscription_stats` conflict columns,
      `lab/packs/postgresql/README.md`) is gated by version, so the pack
      runs on 17, and on 16 if E1 passes there
- [ ] E4 `CDB26` (26ai, no standby) in `lab/oracle` as a compatibility
      check of the receiver and the pack queries, not a second suite (ADR
      0008 decision 3)

### F. Depth

- [ ] F1 Query-level telemetry from `pg_stat_statements` (an ADR on
      cardinality first), autovacuum and dead tuples, wait events
- [ ] F2 Logs in use: every lab ships logs to VictoriaLogs and no rule or
      dashboard panel reads them. One panel and one log rule per engine
- [ ] F3 Host rules beyond filesystem, memory and reboot: disk I/O, OOM
      kills; volume fill and restarts on Kubernetes
- [ ] F4 The overhead measurement repeated with the current pack, after
      the `pg_stat_activity` queries (five scans every 15 s) are merged
      into one

Open after A2 has shown what a chain costs: whether stage3 stays in the
release gate next to pgha, which runs the same Patroni scenarios.

## Known gaps, accepted for now

- `leader-killed` on pgha does not require a leadership change: three of
  the four suite runs kept the old leader, one failed over
  (`pgha-20261118T225346Z-e47dc14`), and `PatroniFailoverHappened` fires on
  a timeline rise in both (`lab/pgha/scenarios/leader-killed.sh`)
- `PostgresTransactionIdWraparound` is unit-tested only; no scenario
  induces it (owner decision 2026-11-19: burning a billion transaction IDs
  tests the lab, and `pg_resetwal` tests `pg_resetwal`)
- `pg_stat_statements` is preloaded in slice1 but nothing reads it
  (`lab/slice1/compose.yaml`); F1
- k8s Collectors and the CloudNativePG Cluster have no resource requests or
  limits (`lab/k8s/otel`, `lab/k8s/cnpg/cluster.yaml`)
- Split-brain alerts (`PatroniMultiplePrimaries`,
  `PostgresMultiplePrimaries`) are unit-tested only, never induced in a lab
- Dashboard metric names are checked only against a running lab
  (`mise run lab:<lab>:panels`)
- Dropping the last replication slot or subscription on purpose fires
  `PostgresSeriesVanished` for up to an hour
  (`lab/packs/postgresql/rules.yml`)
- Compose labs run without TLS, with `trust` authentication in stage3 and a
  Collector as root; pgha shows the hardened form
- The Oracle databases are not built from this repository
  (`lab/oracle/README.md`)

## Stage 5: cloud-managed PostgreSQL

Waits until the project is mature. Cut on 2026-11-19 to one free and one
paid provider. AWS gives managed PostgreSQL hours only to new accounts for
twelve months
([RDS pricing](https://aws.amazon.com/rds/postgresql/pricing/), read
2026-11-07), so the paid provider gets one session of a few hours:

- [ ] One script: create the service, connect the Collector, run the
      scenarios that apply to a managed service and the control, keep the
      evidence, delete everything. A budget alert is set before the first
      paid hour
- [ ] The script rehearsed on a free service: Aiven (free plan) or Supabase
      (Free), chosen when it starts; not Neon, whose free plan suspends
      after five idle minutes
      ([plans](https://neon.com/docs/introduction/plans))
- [ ] Paid, price read again on the day: AWS RDS for PostgreSQL

Unconfirmed until a run: whether the provider's admin role can grant
`pg_monitor`; whether Collector polling keeps a Supabase project from being
paused and an Aiven free service from being powered off; and what changes
when the Collector has to use a pooled endpoint instead of a direct one.

## Managed Oracle

Follows the Oracle first slice (ADR 0008, closed on `main` 2026-11-16);
checked against ADR 0001 before it starts. Read
2026-11-13; the items marked unverified are open until a run settles them.

- [ ] Autonomous Database as a target for `oracledbreceiver`: one Always
      Free instance (two per tenancy, 20 GB, fixed compute, stopped after 7
      idle days, may be deleted after 90 stopped days, no backups;
      [Always Free ADB](https://docs.oracle.com/iaas/autonomous-database-shared/doc/autonomous-always-free.html)),
      a monitoring user granted `SELECT_CATALOG_ROLE` by ADMIN, which has no
      SYSDBA ([ADMIN roles](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-admin-user-roles.html)).
      Wallet-less TLS needs mTLS set to "Not Required"
      ([TLS](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/cdw-connecting-go-wallet-tls.html)).
      Unverified: go-ora over that TLS, which `V$` views ADB lets the
      receiver read, 20 or 30 sessions (the two Oracle pages disagree), 19c
      or 26ai in our home region, and that it uses no A1 or block quota.
      Fallback without OCI: the `adb-free` container (UPL-1.0, 4 CPU, 8 GiB;
      [oracle/adb-free](https://github.com/oracle/adb-free)). Paid options
      (Base Database, RDS for Oracle SE2) only with prices read on the day.

Dropped on 2026-11-19: oracle-database-operator on kind. Its own metrics
are controller-runtime only
([operator metrics](https://github.com/oracle/oracle-database-operator/blob/2.2.0/docs/operator-metrics/README.md)),
its `DatabaseObserver` deploys the exporter ADR 0003 decided against, and
the Free image has no Data Guard, so there is no failover lab in it.

## Homelab as a long-running target

Follows phase D under Next (owner decision 2026-11-19, replacing the wait
for the Oracle items of 2026-11-17): it is the proof that the install path
works outside the lab, with production defaults. Checked against ADR 0001
before it starts. The owner's homelab (a three-node Talos
cluster with two CloudNativePG clusters on PostgreSQL 18, repository
`msavdert/homelab`) runs its own monitoring and does not depend on
obenhub (its decision D46). obenhub attaches beside it as a reader: the
labs are reset between runs, this target is not.

- [ ] An ADR first: how an external target is told apart from the labs
      (every lab uses `service.namespace=obenhub-lab`; ADR 0006 governs
      new attributes), and what counts as evidence. `check-evidence.sh`
      expects injected faults and a control run; a target that is only
      observed needs another record, for example a dated observation
      window with the alerts that fired and why. Also where the store
      for a window of weeks lives: the box is rolled back to a snapshot
      and takes `~/work` with it
- [ ] A backend and gateway for this target, separate from the lab
      stacks, following `lab/pgha` (OTLP/HTTP with mutual TLS on the box
      address) with its own CA
- [ ] The Collector of `lab/k8s/otel/` in a namespace of its own on the
      homelab cluster, sending to that gateway. The homelab provides the
      namespace, a monitoring role (`pg_monitor`) on its clusters and the
      network path as a phase in its own roadmap; obenhub changes nothing
      in the homelab's monitoring
- [ ] The `postgresql`, `cnpg` and `collector` packs against it for a few
      weeks: which lab thresholds fire without a fault, and which rules
      need the inventory the k8s lab leaves empty

Unverified until it starts: that the box and the homelab subnet reach each
other for this (the homelab's D21 says they route through the host); how
the Collector verifies the homelab clusters' server certificates (the k8s
lab skips verification for the `postgresql` receiver); whether
the pack, tested on PostgreSQL 18 with the labs' image, finds what its
queries need in the homelab's minimal 18 image;
and the memory, CPU and database connections the two Collector workloads
and their queries cost on nodes with 8 GiB and a host short of CPU, next
to the homelab's own scraping of the same instances.

## Upstream PR candidates

See [ADR 0003](adr/0003-receiver-strategy.md), decision 3. Each candidate is
checked against existing upstream issues before work starts.

- [ ] `postgresqlreceiver`: replication slot metrics from
      `pg_replication_slots`, version-gated (evidence: slice1 scenarios
      `physical-slot-inactive`, `slot-invalidated`). Issue
      [contrib#53105](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/53105)
      opened 2026-11-13; no code before a code owner agrees on the direction
- [ ] `oracledbreceiver`: role and open mode are read once at start
      (contrib v0.164.0, `scraper.go` `start()`), so they stay stale after a
      switchover until the Collector restarts. Shown in the lab on
      2026-11-13 with contrib 0.164.0 and 0.165.0 (two broker switchovers;
      [record](https://github.com/msavdert/obenhub/blob/main/lab/oracle/results/role-staleness-2026-11-13/README.md));
      no upstream issue found in a search that day (listings were
      truncated, so not proof). Next: the owner opens the issue
- [ ] a login probe per check for Oracle (candidate, pending evidence):
      the gap and its sources are in ADR 0008 decision 7. Evidence to
      collect first: the decision 8 scenarios listener stopped, monitoring
      password expired and ORA-00020 (all three have run once or twice
      outside a suite, results in ADR 0008 decision 7)

## When nothing else is left

Named in ADR 0002 and not built; kept, in no order, behind everything above
(owner decision 2026-11-19):

- [ ] An own Collector distribution built with the OpenTelemetry Collector
      Builder
- [ ] Traces: VictoriaTraces in the reference backend
- [ ] A ClickHouse-based backend compared on the same OTLP stream and the
      same fault scenarios
- [ ] Perses (Apache 2.0, CNCF) re-evaluated against Grafana once it
      supports the VictoriaLogs and VictoriaTraces datasources
