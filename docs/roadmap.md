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
the held dependency update batch and closes a release. That chain ran on 2026-11-22
with the update batch of #145: slice1 `slice1-20261122T073739Z-4f6f8a9`,
stage3 `stage3-20261122T110328Z-4f6f8a9`, k8s `k8s-20261122T121116Z-4f6f8a9`,
pgha `pgha-20261122T140350Z-4f6f8a9` and oracle
`oracle-20261122T174237Z-c0e174e` passed, and `scripts/check-evidence.sh
--strict --full` passes.

### A. Tooling and documents, no lab run

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
- [x] A4 Renovate raised `kubectl` to 1.37.2 against a 1.36.4 kind node
      although `renovate.json` means to hold minors back: its rule matched
      `kind` and `kubectl` by `matchPackageNames`, which matches the package
      name (`kubernetes-sigs/kind`, `kubernetes/kubernetes`), not the
      dependency name. The rule names the package names now; kubectl stays
      at 1.37.2 (within the skew policy; the k8s suite of record ran after #94, and
      `up.sh` checks each tool against its pin).
      `affected-scenarios.sh` treats comment-only TOML changes as nothing
- [x] A5 `release-evidence` as a required check on `main` (owner,
      2026-11-19; the ruleset requires it next to `check` and
      `semantic-title`)
- [x] A6 `lab/obi` and `lab/overhead` reduced to their results pages and
      scripts (`results/cells`, `contaminated-2026-11-06`,
      `2026-11-07-old-pack`)

### B. Defects that need lab runs

- [x] B1 Oracle. `OraclePrimaryChanged` also fires when a primary is
      demoted: the role is an attribute of `oracledb.database.primary`, and
      the `fsfo-failover` record of suite `oracle-20261118T202631Z-37e22f2`
      shows a firing at the reinstate, without a promotion.
      `oracledb.backup.failed` counts a database backup for one kind where
      `oracledb.backup.age` counts it for both, and has no tie-breaker
      (`packs/oracledb-backup/queries.yaml`). The inventory has no
      gateway and no `obenhub.upstream`
      (`lab/oracle/mon/vmalert/inventory.yml`). The `sql_query` receivers in
      `lab/oracle/files/otelcol-obs.yaml` set no `max_open_conn` (ADR 0003).
      The account query matches only `C##OBENHUB\_%`. Done when a unit test
      covers a demotion without a promotion and the backup kinds, and the
      oracle suite passes. Done in #123 and suite
      `oracle-20261119T153131Z-4ac9423` (12 of 12; `fsfo-failover` fired
      `OraclePrimaryChanged` twice, for the two promotions). The backup
      kinds are tested on the rule; the SQL itself only by the suite
- [x] B2 PostgreSQL and Kubernetes rules. The logical-replication rules
      used `increase()` without the counter-start handling the pack
      documents (`PostgresDeadlocks`); moved into `packs/postgresql/rules.yml`
      with last-minus-first and a unit test (C2).
      `KubernetesNodeNotReady` names its node in
      `service.instance.id`, and stage3, pgha and k8s give the `postgresql`
      receiver the database `app` too; done when the full suites of
      stage3, pgha and k8s pass with them (chain of 2026-11-22)
- [x] B3 Harness (`lab/scenarios/lib-core.sh`, `run-suite.sh`, each lab's
      `lib.sh`), with a test per item (`mise run lab:harness-test`, stub
      VictoriaLogs and Alertmanager): the precondition fails when running and
      declared images differ (slice1, stage3, k8s; the record gains
      `running_images`); the unexpected-alert window runs from the end of the
      previous scenario of the suite (`window_start`); `control` sends a
      synthetic alert and counts database log records; resolution is searched
      from detection (`resolved_before_revert`). Done when every lab's full
      suite passes with it (chain of 2026-11-22)
- [x] B4 slice1 Alertmanager: slice1 had its own copy with inhibit rules,
      which race with delivery (`lab/mon/alertmanager.yml`); each was already
      covered by a guard in the rule expression. slice1 now mounts the shared
      file and `scripts/test-alertmanager.sh` checks that nothing is
      inhibited; done when the full slice1 suite passes with it (chain of 2026-11-22)

### C. Packs usable outside the lab

- [x] C1 `lab/packs` moves to `packs/`, paths only (scripts, `mise.toml`,
      lab mounts, tests, generated reference, Renovate file patterns). Done
      when `git grep lab/packs` is empty, `mise run check` passes and every
      lab's full suite passes with it (the mounts changed) (chain of 2026-11-22)
- [x] C2 What the labs kept moved into packs: the logical-replication rules
      (`packs/postgresql`, counter start as in `PostgresDeadlocks`), a
      `pgbouncer` pack, the PostgreSQL, Patroni and CloudNativePG dashboards,
      and `packs/postgresql/monitoring-role.sql` (slice1, stage3, pgha; k8s
      keeps its CNPG managed role, `lab/overhead` its own copy). Done when
      every lab's full suite passes with it, slice1, stage3 and pgha rebuilt
      first (the role SQL runs only at bootstrap). Every full suite passed
      (chain of 2026-11-22); slice1 and stage3 were rebuilt before it, pgha
      was wiped and rebuilt after it (#154) and suite
      `pgha-20261122T215002Z-8037e39` passed 16 of 16 with the role from
      bootstrap (`monitor_role_errors` 0)
- [x] C3 Identity, with an amendment to ADR 0006 first. Every join in the
      `postgresql` pack is on `service.instance.id` alone (13 places), so
      two clusters with a `pg-1` in one backend break the rules, and a
      recreated pod has two series for a few minutes. `obenhub.cluster.name`
      becomes mandatory, joins use cluster, instance and pod UID where
      present, the backend-wide guards (`PostgresStandbyNotStreaming`, the
      etcd member count) become per cluster, and a rule fires on a target
      without a cluster. Done when unit tests with two clusters sharing an
      instance name, and with two pod UIDs for one instance, pass. The tests
      are `packs/{postgresql,patroni,etcd}/tests/*identity.yml`; the stage3
      and pgha etcd resources now carry `stage3-etcd` and `pgha-etcd`, and
      the lab suites run in the chain
- [x] C4 Thresholds: a production default in the rule and an optional
      override series, in one form everywhere, `<expr> > on() group_left()
      (obenhub.<component>.<thing>.limit{...} or on() vector(<default>))`,
      as `packs/etcd/rules.yml` does since #113. 29 limit series in the
      postgresql, oracledb-dg, host, etcd and pgbouncer packs (the patroni
      pack has none: `PatroniReplicaNotEligible` must equal Patroni's
      `maximum_lag_on_failover` and the collection interval and boot window
      stay literal, each with its reason beside it); the owner set each
      production value on 2026-11-20. The labs keep today's values as
      override series in a `<component>-parameters` group of their
      inventory; the dashboards draw the same series (with the same fallback)
      as a dashed line. `docs/reference/<pack>-pack-alerts.md` has a
      generated Thresholds table (series, selector, default, unit,
      comparison) and `scripts/gen-pack-alerts.py` fails on a `.limit`
      series in any other form. Every pack has `tests/thresholds.yml` (the
      defaults, and an override that moves the limit; a tiered rule's
      warning band follows its critical limit) and every lab a
      `limits.yml` test of its own values
- [x] C5 Collection interval: the rules assume 15 s (windows of 30 s in 17
      places, which cannot hold at 60 s). Each pack README that sizes windows
      to its interval (postgresql, pgbouncer, patroni, cnpg, oracledb-dg,
      oracledb-backup) states the interval per source and that a window holds
      at least two collections. `PostgresCollectionIntervalTooLong`,
      `OracleCollectionIntervalTooLong`, `PgbouncerCollectionIntervalTooLong`
      and `PatroniCollectionIntervalTooLong` fire when the samples of the
      target's heartbeat series are on average more than 20 s apart
      (`scrape_interval()` over 5 m, held 10 m); the tests are
      `packs/{postgresql,oracledb-dg,pgbouncer,patroni}/tests/collection-interval.yml`.
      Every window was checked against the interval of its own source (the
      `oracledb` receiver at 30 s, the backup queries at 60 s). The second,
      slower `sqlquery` tier for catalog-heavy queries moved to F1: no
      current query scales with the number of relations, so a tier now
      would be an empty placeholder
- [x] C6 `description` and `runbook_url` on every alert (94 today; all
      carry both and `lint:alert-docs` enforces it), a runbook page only
      for alerts a scenario fires, with the SQL or LogsQL to look at first;
      the runbook pages are in `docs/runbooks/`
- [x] C7 One complete Collector fragment per pack, checked by
      `lint:otelcol`, and inventories generated from a target list,
      byte-equal to the hand-written ones; the fragments are
      `packs/<pack>/otelcol.yaml` on `packs/otelcol-base.yaml` (VM) or
      `packs/otelcol-base-k8s.yaml`, the target lists `lab/<lab>/targets.json`
      (`lab:inventory-check`)

### D. Install path

- [x] D1 `deploy/compose`: the backend and gateway of `lab/mon` on their
      own; Collector configuration for a host and values for the upstream
      Helm chart; an Alertmanager example that routes by severity and has a
      dead-man route for `Watchdog` (stack started clean: every pack's rules
      loaded without a parameters group, `Watchdog` routed to `deadman`, the
      gateway refuses a client without a certificate, a host Collector
      reaches it, `helm template` renders both values files)
- [x] D2 An install test without lab files: a plain PostgreSQL container
      and D1 with production defaults; the heartbeat is there, nothing but
      `Watchdog` fires, the dashboard panels have data
      (`mise run deploy:install-test`, run of 2026-11-20 on 119ff5c, clean
      tree: pass in 844 s; only `Watchdog` firing after a 720 s settle,
      `CollectorAbsent` of the host Collector only in its first 18 s, six
      dead-man notifications 60 s apart, 28 panels with data, 15 empty by
      design, 2 replication slot panels accepted empty; line in
      `deploy/results/runs.jsonl`)
- [x] D3 Quick start on slice1 and the install guide: a stranger reaches a
      fired and resolved alert in under 15 minutes, timed on a clean VM
      (`docs/guides/quick-start.md` run as written on 2026-11-22 on a clean
      Debian 13.7 VM at `2eabe0c`: 539 s of commands, `replay-paused` fired
      in 111.7 s and resolved in 58.3 s, no unexpected alert; reading time
      not measured). These are the first Guides pages on the docs site;
      further Learn pages follow, each for a scenario that runs
- [x] D4 pgha and oracle read their addresses from an untracked file
      (`lab/pgha/nodes.sh`, `lab/oracle/gateway.sh` and `pair.sh`, copied
      from the tracked `*.example.sh`), so that the labs run elsewhere on a
      clean tree (`mise run check` passes in a fresh clone without the three
      files; the scripts stop with one line naming the example to copy);
      done when the full suites of pgha and oracle pass with it, in the
      chain of phases B and C (chain of 2026-11-22)

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
      `packs/postgresql/README.md`) is gated by version, so the pack
      runs on 17, and on 16 if E1 passes there
- [ ] E4 `CDB26` (26ai, no standby) in `lab/oracle` as a compatibility
      check of the receiver and the pack queries, not a second suite (ADR
      0008 decision 3)

### F. Depth

- [ ] F1 Query-level telemetry from `pg_stat_statements` (an ADR on
      cardinality first; database-level totals and a bounded top-K, never a
      series per `queryid`), autovacuum and dead tuples, wait events.
      First step: read what the pinned `postgresqlreceiver` already emits
      for dead tuples, vacuum counts and the checkpointer, and write pack
      SQL only for the rest. Autovacuum is a count per database of tables
      past their effective threshold (per-table `reloptions` honoured,
      tables without recent writes left out), a count of tables with
      autovacuum disabled, and the global `autovacuum` and `track_counts`
      settings; wait events are sessions by state, wait event type and
      wait event. The autovacuum count scales with the number of
      relations, so it is the first query of a second, slower `sqlquery`
      tier (5 minutes) so it never runs at 15 s on a busy primary; the
      pack README states that interval (C5) and the rules over it use
      windows that hold at it. Each signal comes with a scenario
- [ ] F2 Logs in use: every lab ships logs to VictoriaLogs and no rule or
      dashboard panel reads them. One panel and one log rule per engine
- [ ] F3 Host rules beyond filesystem, memory and reboot: disk I/O, OOM
      kills; volume fill and restarts on Kubernetes
- [ ] F4 The overhead measurement repeated with the current pack, after
      the `pg_stat_activity` queries (five scans every 15 s) are merged
      into one
- [ ] F5 Signals taken as ideas from the dasha review (owner, 2026-11-19),
      each with a rule and a scenario, in this order: `safe_wal_size` in
      the slot query with the time until a slot is lost computed in
      MetricsQL from the WAL rate (also a candidate for the upstream slot
      work below); sequence exhaustion against the owning column's type
      ceiling, as the highest ratio per database; then, lower priority,
      lock-table saturation and a count of invalid indexes and unvalidated
      constraints. The sequence and invalid-index queries scale with the
      number of relations and use the slower tier F1 creates. The sequence
      query needs a grant in the monitoring role (C2)

Method references for F1 and F5: github.com/dbulashev/dasha is GPL-3.0, so
it is read for how a signal is derived and nothing is copied from it; the
SQL is written from the PostgreSQL documentation. Where a query is adapted
from a permissive source (postgres_dba, BSD-3-Clause; pghero and
db_verifier, MIT), ADR 0004 applies. Considered and left out: a composite
health score, an index advisor, schema linting, continuous bloat
estimation and plan comparison from `auto_explain` logs, which are
per-object diagnostics for a user interface, not signals for a metrics
pipeline.

stage3 stays in the release gate next to pgha (owner, 2026-11-19): its full
suite takes about an hour (66 minutes, `stage3-20261118T214721Z-e47dc14`),
and it is the Patroni lab that runs without the owner's VMs.

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
  (`packs/postgresql/rules.yml`)
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
      truncated, so not proof). Fix implemented on the owner's fork
      (branch `receiver-oracledb-role-refresh`), split: PR1 per-scrape
      role and open mode refresh, PR2 retry of a failed start detection
      later; [lab evidence](https://github.com/msavdert/obenhub/blob/main/lab/oracle/results/role-refresh-2026-11-21/README.md).
      Next: the owner opens the issue and PR1
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
