# ADR 0004: Licence policy

- Status: Accepted
- Date: 2026-11-06

## Context

The project is fully open source under Apache 2.0. It ships configuration,
SQL, a Collector build manifest, dashboards, alert rules and possibly small
amounts of Go; it also runs third-party services in its labs.

## Decision

1. Everything in this repository is Apache-2.0 (`LICENSE`), documentation
   included.
2. What the project ships or builds (Collector distribution, any Go code and
   its dependency closure) contains no GPL or AGPL components. Permissive
   licences (Apache-2.0, MIT, BSD, ISC, PostgreSQL, UPL) are allowed; anything
   else needs a recorded decision.
3. Services the lab and the reference backend run as separate, unmodified
   processes may be under other OSI licences. Grafana OSS (AGPL-3.0) is
   accepted on that basis. Source-available licences (SSPL, BSL, Elastic) are
   not used.
4. SQL or configuration copied from another project keeps its origin: the
   source file, the upstream licence and the commit are recorded next to it,
   and the upstream licence must be compatible with Apache 2.0. Ideas and
   designs are reimplemented rather than copied when the licence is unclear.
5. Every dependency of what the project ships or builds is listed with its
   licence and the source checked, in a machine-checked table (the
   `licences.toml` pattern from the private dbwitness repository), from the first such dependency
   on. There is none yet. Development tools (`mise.toml`) and workflow
   actions are not shipped; Renovate keeps them current.

## Consequences

- Before a query pack borrows SQL from pg_exporter, pgMonitor, sql_exporter,
  postgres_exporter or Oracle's exporter, that project's licence is read from
  its `LICENSE` file, not assumed.
- A licence protects the code, not the name; the project name is checked
  separately before any public release.
