# shellcheck shell=bash disable=SC2034
# One official PostgreSQL image per supported major, for scripts/test-pack-sql.py
# and scripts/pack-catalog-diff.py (read as text by scripts/packsql.py, also
# sourceable). Supported = not end of life on endoflife.date/api/postgresql.json
# (read 2026-11-23: 15, 16, 17, 18; 14 ended 2026-11-12; 19 released 2026-11-19,
# postgresql.org/support/versioning read 2026-11-24).
# The 18 line is the image lab/stage3 and lab/pgha pin. Renovate moves tag and
# digest together (renovate.json, customManagers: tag@digest in lab, pack and
# deploy shell scripts) and may not change the major (packageRules: postgres
# major updates are disabled). Digests are the multi-arch index digests, read
# with `docker buildx imagetools inspect postgres:<tag>` on 2026-11-23.
# renovate: datasource=docker
PG_IMAGE_15=postgres:15.20-trixie@sha256:8cf673eb99f8b9042c9078ee4ca0e775428c77097e9d999bfc9ba4b4347f5733
# renovate: datasource=docker
PG_IMAGE_16=postgres:16.16-trixie@sha256:3950ad7c3148ca2175ef1b6c36c9efbf78957ae8fbe8b3a5d7c35af50500382f
# renovate: datasource=docker
PG_IMAGE_17=postgres:17.12-trixie@sha256:223efeb196329b55b3b9a13db144956411dbc18e727e59f681c3e0aede6475cf
# renovate: datasource=docker
PG_IMAGE_18=postgres:18.7-trixie@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a
# renovate: datasource=docker
PG_IMAGE_19=postgres:19.0-trixie@sha256:908d19593a1444b2d4e85783f718b16e0d40f1baf7518420475df9e5f5ac67a2
