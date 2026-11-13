# ADR 0007: Backup tool - pgBackRest, compared with pg_basebackup

- Status: Accepted
- Date: 2026-11-12

## Context

slice1 archives WAL (`archive_command`, scenario `archiver-failing`) but
takes no base backup and never restores. The roadmap asks for one backup tool
in one lab, with backup age and verification monitored, an alert for a stale
or failed backup, and a restore scenario with evidence.

Candidates, read on 2026-11-12:

- pgBackRest 2.60.0 (2026-10-18). `LICENSE` read at commit
  `2e1c4f2ba727c45a0a23d4b326905088dc15b1a1`: MIT. The PostgreSQL 18 catalog
  number was finalised in 2.57.0 (`doc/xml/release/2020s/2025/2.57.0.xml:83`);
  2.59.2 supports 19beta4/rc1. The maintainer announced on 2026-04-27 that he
  had stopped and on 2026-05-18 that development continues, funded by a group
  of sponsors (<https://pgbackrest.org/news.html>). PGDG ships
  `2.60.0-1.pgdg13+1` for Debian 13 (seen with `apt-cache policy` on a pgha
  node). `pgbackrest info --output=json` is documented as stable
  (<https://pgbackrest.org/user-guide.html>, Monitoring).
- Barman 3.20.1 (2026-09-29), GPL-3.0. As a separate, unmodified process in a
  lab it is allowed by ADR 0004 decision 3; it was not ruled out on licence.
  Its release notes read so far do not mention PostgreSQL 18.
- WAL-G 3.0.9 (2026-08-20), Apache-2.0. Its CI runs PostgreSQL 14 to 18; no
  support statement for 18 was found.
- PostgreSQL 18 itself: `pg_basebackup` (incremental since 17, with
  `summarize_wal`), `pg_combinebackup`, `pg_verifybackup`. No catalogue, no
  retention, nothing that records when the last good backup was taken.

## Decision

1. pgBackRest is the backup tool, first in slice1, installed from PGDG and
   pinned like the other packages. It takes over WAL archiving there
   (`archive-push`); the `archiver-failing` scenario keeps its alerts.
2. Backup state reaches the Collector from `pgbackrest info --output=json`.
   How (an upstream receiver, an existing exporter or a small converter) is
   chosen during implementation, with its licence read, and the choice is
   added to this ADR before it merges.
3. One scenario does the same job with PostgreSQL's own tools: a full and an
   incremental `pg_basebackup`, `pg_combinebackup`, `pg_verifybackup`, and a
   point-in-time restore. It has no alert of its own; it shows what a tool
   like pgBackRest adds (catalogue, retention, a readable backup state).
4. `pg_dump` is not part of this stage: a logical dump is not a physical
   backup and cannot replay WAL to a point in time.

## Consequences

- PostgreSQL 18.7 (2026-11-12) says existing incremental backup files
  should not be trusted after the update; the stage starts on 18.7, so no
  backup older than it exists.
- pgBackRest support for the PostgreSQL 19 release (not the release
  candidate) is unconfirmed until a pgBackRest release states it; for 18 the
  final catalogue number came in a release after 18.0.
- Barman stays the documented alternative; CloudNativePG backups (the Barman
  Cloud plugin) are a separate item for the k8s lab, not part of this ADR.
