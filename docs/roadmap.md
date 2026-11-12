# Roadmap

The only place for plans, open items only: what runs is described in
`lab/README.md` and each lab's README. Scope and order are
decided in [ADR 0001](adr/0001-goal-and-scope.md).

## Next

The hardening pass of the 2026-11-11 project review is done: every lab passed
its full suite on `main` (`scripts/check-evidence.sh --strict <lab>` passes for
slice1, stage3, pgha and k8s). What follows is the owner's decision; Stage 5
is not next (owner decision 2026-11-08).

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
