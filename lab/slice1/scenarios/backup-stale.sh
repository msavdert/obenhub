#!/usr/bin/env bash
# Scenario backup-stale: stop the pgbackrest-backup service, so no backup completes; expect PgBackRestBackupStale once the age of the last backup passes the lab parameter (obenhub.max_backup_age, 420 s in vmalert/rules/pgbackrest.yml) for 1 m. The service takes a backup every 240 s, so detection takes up to about 8 minutes from the stop. The revert starts the service again (its first backup is a full one), which resolves the alert.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=("PgBackRestBackupStale:pgbackrest")
inject() { dc stop "$BACKUP_SVC" >/dev/null; }
revert() { dc start "$BACKUP_SVC" >/dev/null; }
run_scenario backup-stale
