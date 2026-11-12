# Roadmap

The only place for plans, open items only: what runs is described in
`lab/README.md` and each lab's README. Scope and order are
decided in [ADR 0001](adr/0001-goal-and-scope.md).

## Next: hardening pass

Stages 1 to 4 have run (slice1, stage3, pgha, k8s). Decided 2026-11-11: the
work items of the project review of that date come first, and no new stage
starts before they are done. Stage 5 is not next (owner decision 2026-11-08).
A stage is done when its fault scenarios fire the expected alerts and show on
the dashboards, with a no-fault control run (ADR 0001), so the open items
below are what keeps stage 4 and pgha from meeting that bar.

- [ ] Naming contract per ADR 0006 (in review as a pull request)
- [ ] Query fixes: snapshot oldest-age scope, slot query on standbys, slice1
      monitors the `app` database
- [ ] WAL archiving in slice1, `pg_stat_archiver` alerts and an
      archiver-failing scenario
- [ ] One `synchronous_mode` scenario in pgha
- [ ] Dashboards: CloudNativePG/Kubernetes for `lab/k8s` (it mounts stage3's
      dashboard directory, which has no `cnpg_` or `k8s.` panels) and host
      (operating system) for `lab/pgha`
- [ ] Dedupe shared lab code: common monitoring Compose base, one
      `gen-env.sh`, shared Patroni scenarios, stage3 Collector template
- [ ] Low-severity fixes: image digests, passwords on command lines, fixed
      sleeps, resource limits
- [ ] k8s tool pinning (in review)
- [ ] Redo the overhead measurement with the current pack and a
      CPU-saturated arm
- [ ] Full suites of all four labs on one `main` commit; record the
      `leader-killed` outcome or adjust its text

## Backups

Not covered yet: backups and point-in-time recovery (PITR). WAL archiving and
`synchronous_mode` are being added to the labs separately; a backup tool is a
stage of its own, because it brings a component, storage and a restore
scenario.

- [ ] Choose a backup tool (pgBackRest or Barman) and read its `LICENSE` file
      per [ADR 0004](adr/0004-licence-policy.md) before choosing. Then:
      the tool in one lab, backup age and verification monitored, an alert
      for a stale or failed backup, and a restore scenario with evidence

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

## Upstream PR candidates

See [ADR 0003](adr/0003-receiver-strategy.md), decision 3. Each candidate is
checked against existing upstream issues before work starts.
