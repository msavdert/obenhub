# Roadmap

The only place for plans, open items only: what runs is described in
`lab/README.md` and each lab's README. Scope and order are
decided in [ADR 0001](adr/0001-goal-and-scope.md).

## Next

Every lab has a full suite recorded on `main`; the evidence is in each lab's
`results/runs.jsonl` and `scripts/check-evidence.sh --strict <lab>` verifies
it. Order decided by the owner on 2026-11-12 (ADR 0001, depth before
breadth), Oracle moved up on 2026-11-13; Stage 5 is not next (owner
decision 2026-11-08):

- [ ] Update wave: PostgreSQL 18.7 in every lab, etcd 3.7.3 if the stage3
      run passes (PR #8), and the pending Collector, VictoriaMetrics and
      Alertmanager updates; then one full suite chain on `main`
- [ ] Backup tool with a restore scenario in slice1, building on its WAL
      archive (see Backups)
- [ ] PostgreSQL 19 (release 2026-11-19, owner decision 2026-11-12) next to
      18 in slice1: the same suite on both majors, the pack's queries tested
      on both. Before it starts, check 19 support in the `postgresql`
      receiver, pgBackRest and the official image
- [ ] Monitoring gaps in slice1: dashboard panels for transaction-id age,
      idle-in-transaction, locks, deadlocks and checkpoints; a scenario for
      `PostgresTransactionIdWraparound` and one for
      `PostgresReplicationSlotRetainingWAL` outside k8s
- [ ] First Learn and Guides pages on the docs site, only for things that run
- [ ] Oracle first slice (ADR 0008), in parallel with the PostgreSQL items
      above (owner decision 2026-11-13)
- [ ] Version drift, every engine (owner decision 2026-11-13): a generated
      catalog diff between two versions of an engine (PostgreSQL majors;
      Oracle release updates and 19c against 26ai) that lists new and changed
      monitoring views and columns, run when Renovate or the EOL check brings
      a new version; queries in the packs carry the versions they support,
      and the pack tests run on every supported version. First use: the
      PostgreSQL 19 item above

## Backups

Not covered yet: backups and point-in-time recovery (PITR). WAL archiving is
in slice1 (scenario `archiver-failing`) with no restore. A backup tool is a
stage of its own, because it brings a component, storage and a restore
scenario.

pgBackRest, with a `pg_basebackup` comparison scenario
([ADR 0007](adr/0007-backup-tool.md)).

- [ ] pgBackRest in slice1, backup age and verification monitored, an alert
      for a stale or failed backup, and a restore scenario with evidence
- [ ] The `pg_basebackup` scenario of ADR 0007 decision 3

## Known gaps, accepted for now

- `leader-killed` on pgha never asserts a leadership change; both recorded
  runs took the no-change branch, while `PatroniFailoverHappened` fires on a
  timeline rise (`lab/pgha/scenarios/leader-killed.sh`)
- The PostgreSQL pack has no version branching and is tested on 18 only
  (`lab/packs/postgresql/README.md`)
- PgBouncer rules live in `lab/slice1/vmalert/rules/postgresql.yml`, not in a
  pack
- `pg_stat_statements` is preloaded in slice1 but nothing reads it
  (`lab/slice1/compose.yaml`)
- Thresholds are hand-copied between pack rules, Patroni config and
  dashboards, for example 16 MiB in `lab/packs/patroni/rules.yml`,
  `lab/pgha/files/patroni.yml.tmpl` and
  `lab/stage3/grafana/dashboards/patroni.json`
- k8s Collectors and the CloudNativePG Cluster have no resource requests or
  limits (`lab/k8s/otel`, `lab/k8s/cnpg/cluster.yaml`)
- The overhead measurement predates two pack queries and two changed ones
  (`lab/overhead/results/results.md`)
- Split-brain alerts (`PatroniMultiplePrimaries`,
  `PostgresMultiplePrimaries`) are unit-tested only, never induced in a lab
- Dashboard metric names are checked only against a running lab
  (`mise run lab:<lab>:panels`)

## Stage 5: cloud-managed PostgreSQL

Waits until the project is mature. AWS and Azure give managed PostgreSQL
hours only to new accounts for twelve months
([RDS pricing](https://aws.amazon.com/rds/postgresql/pricing/),
[Azure free services](https://azure.microsoft.com/en-us/pricing/free-services)),
OCI has no free tier for it
([billing](https://docs.oracle.com/en-us/iaas/Content/postgresql/billing.htm)),
and no free Cloud SQL tier was found (all read 2026-11-07). So each paid
provider gets one session of a few hours:

- [ ] One script per provider: create the service, connect the Collector,
      run the scenarios that apply to a managed service and the control,
      keep the evidence, delete everything. A budget alert is set before
      the first paid hour
- [ ] The script rehearsed first on free services: Aiven (free plan) and
      Supabase (Free); Neon for short runs only, because its free plan has
      100 compute-hours a month and suspends after five idle minutes
      ([plans](https://neon.com/docs/introduction/plans)), so polling
      would keep it awake and use them up
- [ ] Paid, prices read again on the day: AWS RDS for PostgreSQL, Azure
      Database for PostgreSQL flexible server, Google Cloud SQL, OCI Database
      with PostgreSQL

Unconfirmed until a run: whether each provider's admin role can grant
`pg_monitor`; whether Collector polling keeps a Supabase project from being
paused and an Aiven free service from being powered off; and what changes
when the Collector has to use a pooled endpoint instead of a direct one.

## Managed Oracle and Oracle on Kubernetes

Waits until the Oracle first slice (ADR 0008) and its scenarios are done on
`main`; checked against ADR 0001 before it starts. Managed comes first. Read
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
- [ ] oracle-database-operator 2.2.0 (UPL-1.0, `ff6f917`) on the kind
      cluster, as a spike first: the operator plus one
      `SingleInstanceDatabase` with the Free image. The operator is a
      control plane, not monitoring: its own metrics are controller-runtime
      only, with no database status
      ([operator metrics](https://github.com/oracle/oracle-database-operator/blob/2.2.0/docs/operator-metrics/README.md)),
      and its `DatabaseObserver` deploys the appdev exporter (ADR 0003) for
      Prometheus. Free has no Data Guard (2 threads, 2 GB RAM, 12 GB data;
      [Licensing Information 26](https://docs.oracle.com/en/database/oracle/oracle-database/26/dblic/Licensing-Information.html),
      Table 1-5), and the `DataguardBroker` CRD needs Enterprise images and
      leaves switchover to DGMGRL
      ([SIDB](https://github.com/oracle/oracle-database-operator/blob/2.2.0/docs/sidb/README.md)),
      so there is no failover lab here as there is with CloudNativePG.
      Unverified: whether it starts on kind (not in its platform list) and
      its memory needs there. Kept or dropped by an ADR after the spike.

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
      switchover until the Collector restarts. Issue after the `lab/oracle`
      fast-start failover scenario shows it; upstream not searched yet
