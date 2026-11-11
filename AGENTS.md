# AGENTS.md

obenhub is an OpenTelemetry-centred database and operating-system monitoring
learning platform, Apache-2.0, PostgreSQL first. See README.md. Four labs
run PostgreSQL topologies with fault scenarios and alerting; `lab/README.md`
lists them.

## Where things live

- Decisions: `docs/adr/` (index and template in `docs/adr/README.md`).
- Plans: `docs/roadmap.md` only. Nowhere else.
- Labs: `lab/<name>/` (slice1, stage3, pgha, k8s; overhead and obi are
  one-off measurements). Each lab keeps its evidence in `results/runs.jsonl`.
- Shared lab code: queries and rules with unit tests in `lab/packs/<component>/`,
  the scenario harness in `lab/scenarios/lib-core.sh`. A new lab reuses these
  instead of copying another lab's files.
- Repository tooling: `mise.toml`, `scripts/`, `.github/`.
- `CLAUDE.local.md` is machine-specific and gitignored.

## Working rules

- Conventional Commits (feat, fix, docs, chore, ci, build, refactor, perf,
  test, revert; optional scope; `!` for breaking). The PR title is the
  squashed commit message.
- Documents describe what runs. Plans go only in `docs/roadmap.md`.
- Depth before breadth (ADR 0001): finish the first PostgreSQL slice before a
  second engine or topology. Check breadth requests against the ADR.
- Metric and attribute naming follows the naming contract ADR 0002 calls
  for. It is written with the first query pack; until then, follow the
  upstream receivers and the semantic conventions.
- Prefer standard upstream building blocks over custom code (ADR 0001, 0003).
- Licences (ADR 0004): everything is Apache-2.0; no GPL or AGPL in what the
  project ships or builds. SQL or configuration copied from another project
  records source file, upstream licence and commit next to it, and the
  upstream licence is read from its `LICENSE` file, not assumed.
- `mise run check` must pass before every commit. `mise run eol` needs network
  and is run separately.
- No emoji. English in repository files.
- Never commit secrets. Credentials come from 1Password `op://` references
  injected per command.
- Mark assumptions and unconfirmed versions as such.
- Every workflow action is pinned by full commit SHA with a version comment.

## Keeping it real

The private predecessor dbsight was judged AI slop by more than half of the
reviewers the owner asked: 47% of its lines were Markdown and nothing it
promised ran end to end. These are habits to keep, not gates:

- Running code and lab evidence come first; prose follows them. A page is
  written when the thing it describes runs, or when it explains a source that
  was actually read.
- Every claim about OpenTelemetry or database behaviour names its source: a
  spec or semantic-conventions version, an upstream file at a commit, a
  database doc for a major version, or a lab run. Unchecked claims are marked
  as such or left out.
- Prefer generated reference (metric lists, config reference) over
  hand-written copies that drift.
- Say a thing once and link to it; do not restate ADRs elsewhere.
- No placeholder pages, no "coming soon", no summaries of summaries. Shorter
  beats complete; delete rather than pad.
- Before a release, reread what changed and ask whether a sceptical reviewer
  would call it padding. Cut what they would.
