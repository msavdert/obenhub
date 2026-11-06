# Contributing

## Setup

Tools are pinned in `mise.toml` and used identically locally and in CI.

```sh
mise install
mise run check
```

`mise run check` runs all offline linters (workflows, YAML, Markdown,
spelling, relative links, editorconfig, shell). `mise run eol` checks product
end-of-life dates and needs network.

## Commits and pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): subject`, with type one of feat, fix, docs, chore, ci, build,
  refactor, perf, test, revert, and `!` after the type or scope for a breaking
  change.
- Pull requests are squash-merged. The PR title becomes the commit message, so
  it must follow the same format; CI checks it.
- A revert commit pushed to `main` may keep git's default `Revert "<subject>"`;
  a revert PR title uses `revert: <subject>`.
- Releases are cut by release-please from the commit history (SemVer, 0.x
  while unstable, tags `vX.Y.Z`). The first release is 0.1.0
  (`initial-version`). Release PRs are opened with the workflow token, so CI
  does not run on them; they only touch `CHANGELOG.md`, `version.txt` and the
  manifest.

## Repository settings

Set once on GitHub, not in files: Pages source "GitHub Actions"; Actions may
create pull requests; squash merge only, branches deleted after merge; `main`
blocks force pushes and deletion; private vulnerability reporting on.
Scheduled workflows (the weekly EOL check) are disabled by GitHub after 60
days without repository activity and must then be re-enabled.

## Documentation

The site is built with Zensical from `docs/` (`mise run docs:serve` to preview)
and published to GitHub Pages from `main`. Pages fall into four kinds, and a
section appears in the navigation only once it has a real page:

- **Learn**: how OpenTelemetry and the database fit together, written from
  sources that were read (spec version, upstream file and commit, database
  docs) and from lab runs.
- **Guides**: how to monitor a given topology, written once that topology runs
  in the lab.
- **Reference**: metrics, events, attributes and configuration, generated from
  the source where possible.
- **Decisions**: the ADRs.

See "Keeping it real" in [AGENTS.md](AGENTS.md) for the writing habits.

## Decisions

A decision that changes scope, architecture, licensing or a naming contract is
recorded as an ADR in `docs/adr/`: take the next free number, copy the template
in [docs/adr/README.md](docs/adr/README.md), and add the ADR to the index.
Plans belong in [docs/roadmap.md](docs/roadmap.md), not in ADRs or READMEs.

## Rules

Everything is Apache-2.0. Read [AGENTS.md](AGENTS.md) for the working rules
(licence attribution for copied SQL, no emoji, no secrets).
