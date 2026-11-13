#!/usr/bin/env bash
# Scenario backup-stale: take a backup, then stop the pgbackrest-backup service, so no further backup completes; expect PgBackRestBackupStale once the age of the last backup passes the lab parameter (obenhub.backup_age.limit, 780 s in vmalert/rules/pgbackrest.yml) for 1 m. The age starts at 0 (a backup is taken at the stop), so detection takes about 15 minutes. The revert takes an incremental backup (resume_backups, the age is past the interval) and starts the service again, which resolves the alert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgBackRestBackupStale:pgbackrest")
# threshold 780 s + exporter refresh 30 s + scrape 30 s + evaluation 15 s + for 60 s + margin 120 s = 1035 s, rounded up
DETECT_TIMEOUT=1200
# one backup is taken first (age 0), then the periodic ones stop
inject() { pause_backups; }
revert() { resume_backups; }
run_scenario backup-stale
