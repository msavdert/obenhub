#!/usr/bin/env bash
# Scenario basebackup-compare: the backup job with PostgreSQL 18's own tools instead of pgBackRest (ADR 0007 decision 3). In a throwaway container with a named volume: a full `pg_basebackup`, more writes, an incremental `pg_basebackup --incremental` against the full one's backup_manifest, `pg_combinebackup` of the two, `pg_verifybackup` of the result, then a point-in-time restore of the combined backup to a recovery target between known writes (WAL from the pgBackRest archive through `archive-get`, the restore container has no network). Rows written before the full backup, between full and incremental, and after the incremental but before the target must exist; rows written after the target must not. Needs summarize_wal=on on the primary (compose.yaml). Each step's duration, the backup sizes and the counts go into the result row (extra); the log ends with what pgBackRest gives that this path does not. Both backups are requested checkpoints, so it first waits for headroom under PostgresCheckpointsRequested. No alert is expected; any alert in the window is unexpected, as in control.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECT=()
ROWS=20
BALLAST_ROWS=100000   # about 10 MB, so that full and incremental differ in size
BB_VOL=${PROJECT}_basebackup-compare
BB_C=${PROJECT}-basebackup-compare
BB_HOST=pg-primary-repl   # alias on the repl network, where pg_hba allows the replicator

# Runs as root in a throwaway container: $1.. is a command, run as postgres,
# its output goes to stderr, stdout is the duration in milliseconds.
STEP_SCRIPT=$(cat <<'EOS'
t0=$(date +%s%N)
gosu postgres "$@" >&2
rc=$?
echo $((($(date +%s%N) - t0) / 1000000))
exit "$rc"
EOS
)

# Runs as root with the restore network off: turn the combined backup into a
# point-in-time recovery to $1, start it on a socket only, wait for recovery to
# end, print "ms=N full=A incr=B wal=C after=D".
RESTORE_SCRIPT=$(cat <<'EOS'
set -eu
D=/bb/combined
t0=$(date +%s%N)
{
  echo "restore_command = 'pgbackrest --stanza=slice1 --pg1-path=$D archive-get %f \"%p\"'"
  echo "recovery_target_time = '$1'"
  echo "recovery_target_action = 'promote'"
} >>"$D/postgresql.auto.conf"
touch "$D/recovery.signal"
chown postgres:postgres "$D/postgresql.auto.conf" "$D/recovery.signal"
gosu postgres pg_ctl -D "$D" -l /tmp/pg.log -w -t 120 \
  -o "-c listen_addresses= -c archive_mode=off -c unix_socket_directories=/tmp" start >&2 || { cat /tmp/pg.log >&2; exit 1; }
q() { gosu postgres psql -h /tmp -U postgres -X -At "$@"; }
n=0
until [ "$(q -c "SELECT pg_is_in_recovery()")" = f ]; do
  n=$((n + 1)); [ "$n" -lt 60 ] || { echo "recovery did not end" >&2; cat /tmp/pg.log >&2; exit 1; }
  sleep 1
done
ms=$((($(date +%s%N) - t0) / 1000000))
c() { q -c "SELECT count(*) FROM bb_marker WHERE phase = '$1'"; }
echo "ms=$ms full=$(c full) incr=$(c incr) wal=$(c wal) after=$(c after)"
gosu postgres pg_ctl -D "$D" -m fast stop >&2
EOS
)

# bb_run NETWORK script args...: sh -c script in a throwaway container on the
# volume and the pgBackRest repository (read-only). PGPASSWORD, when set, is
# passed by name, never in argv.
bb_run() {
  local net=$1; shift
  docker run --rm --name "$BB_C" --network "$net" -e PGPASSWORD -v "$BB_VOL:/bb" -v "$REPO_VOL:/var/lib/pgbackrest:ro" \
    --entrypoint sh "$PG_IMAGE" -c "$@"
}
# bb_step NETWORK command...: bb_run with STEP_SCRIPT; prints the milliseconds
bb_step() {
  local net=$1; shift
  bb_run "$net" "$STEP_SCRIPT" sh "$@"
}
# bb_step on the repl network as the replicator (password from lab/slice1/.env)
repl_step() { PGPASSWORD=$REPLICATOR_PASSWORD bb_step "$REPL_NET" "$@"; }
# size in MB of a backup directory without pg_wal (the data the backup copied)
bb_size_mb() {
  # shellcheck disable=SC2016
  bb_run none 'du -sm --exclude=pg_wal "$1" | cut -f1' sh "$1"
}

# Both pg_basebackup runs are requested checkpoints, and PostgresCheckpointsRequested
# fires above 3 in 5 minutes (lab/packs/postgresql/rules.yml; a third run within
# five minutes of two others tripped it, 2026-11-13). The periodic pgBackRest
# backup (also a requested checkpoint) is paused for the run with one backup
# taken first (pause_backups), so the backup age stays below the interval and
# revert (resume_backups) takes no further one; the run then starts only when
# the primary's own window (the rule's expression, from VictoriaMetrics) holds
# none: a checkpoint taken after the last scrape is not visible yet, so one
# unseen plus the two of this run stays at the threshold.
checkpoint_headroom() {
  local n
  n=$(vm_query 'max(last_over_time({__name__="postgresql.bgwriter.checkpoint.count",type="requested","service.instance.id"="pg-primary"}[5m]) - first_over_time({__name__="postgresql.bgwriter.checkpoint.count",type="requested","service.instance.id"="pg-primary"}[5m]))')
  [ -n "$n" ] && [ "$n" -le 0 ]
}

summary() { # what pgBackRest gives for the same job, from the lab's repository, against this path
  log "comparison: pgBackRest catalogue of the same cluster (pgbackrest info): $(pgbr info --output=json | jq -r '.[0] | "stanza \(.status.message), \(.backup | length) backups listed (\(.backup[0].label) .. \(.backup[-1].label)), WAL archive \(.archive[0].min) .. \(.archive[0].max)"')"
  log "comparison: retention is configured (repo1-retention-full=$(docker exec "$PRIMARY" sed -n 's/^repo1-retention-full=//p' /etc/pgbackrest/pgbackrest.conf)); backup age is $(backup_age)s and reaches the monitoring stack as a metric (PgBackRestBackupStale)"
  log "comparison: this path left three unrelated directories on a volume (full, incremental, combined): no catalogue to list or choose a restore point from, no retention or expiry of old backups or of the WAL they need, no backup age metric or alert, no repository-wide check (pg_verifybackup checks the files and WAL range of one backup directory at a time), and the restore needed hand-written recovery settings"
}

inject() {
  local ms_full ms_incr ms_combine ms_verify out lsn target
  local size_full size_incr size_combined
  local sw
  pause_backups || { FAILS+=("pausing the periodic backups (stop and one backup) failed"); return 1; }
  wait_until 600 "no requested checkpoint on the primary in the last 5 minutes" checkpoint_headroom || return 1
  # a volume or container left by a killed run would make the next one fail
  docker rm -f "$BB_C" >/dev/null 2>&1 || true
  docker volume rm "$BB_VOL" >/dev/null 2>&1 || true

  sw=$(psql_p -c "SHOW summarize_wal") || return 1
  [ "$sw" = on ] || { FAILS+=("summarize_wal is $sw on the primary; incremental backup needs on (compose.yaml, or ALTER SYSTEM and reload)"); return 1; }

  psql_p -c "DROP TABLE IF EXISTS bb_marker, bb_ballast" \
    -c "CREATE TABLE bb_marker (id serial PRIMARY KEY, phase text NOT NULL, at timestamptz NOT NULL DEFAULT clock_timestamp())" \
    -c "CREATE TABLE bb_ballast AS SELECT g AS id, md5(g::text) || md5((g * 7)::text) AS pad FROM generate_series(1, $BALLAST_ROWS) g" \
    -c "INSERT INTO bb_marker (phase) SELECT 'full' FROM generate_series(1, $ROWS)" \
    -c "VACUUM bb_ballast" >/dev/null || return 1   # its visibility-map changes land before the full backup, not in the incremental
  docker volume create "$BB_VOL" >/dev/null || return 1
  docker run --rm -v "$BB_VOL:/bb" --entrypoint sh "$PG_IMAGE" -c 'chown postgres:postgres /bb && chmod 700 /bb' || return 1

  # 1. full backup (checkpoint=fast: a requested checkpoint, like pgBackRest's start-fast)
  ms_full=$(repl_step pg_basebackup -h "$BB_HOST" -U replicator -w -D /bb/full -c fast -X stream) \
    || { FAILS+=("full pg_basebackup failed"); return 1; }
  log "full pg_basebackup: ${ms_full} ms"

  # 2. writes that only the incremental backup (and WAL) can carry
  psql_p -c "UPDATE bb_ballast SET pad = pad || 'x' WHERE id <= 1000" \
    -c "INSERT INTO bb_marker (phase) SELECT 'incr' FROM generate_series(1, $ROWS)" >/dev/null || return 1

  # 3. incremental backup against the full one's manifest
  ms_incr=$(repl_step pg_basebackup -h "$BB_HOST" -U replicator -w -D /bb/incr -c fast -X stream --incremental=/bb/full/backup_manifest) \
    || { FAILS+=("incremental pg_basebackup failed"); return 1; }
  log "incremental pg_basebackup: ${ms_incr} ms"

  # 4. combine
  ms_combine=$(bb_step none pg_combinebackup -o /bb/combined /bb/full /bb/incr) || { FAILS+=("pg_combinebackup failed"); return 1; }
  log "pg_combinebackup: ${ms_combine} ms"

  # 5. verify the combined backup (it carries its own backup_manifest)
  ms_verify=$(bb_step none pg_verifybackup /bb/combined) || { FAILS+=("pg_verifybackup failed"); return 1; }
  log "pg_verifybackup: ${ms_verify} ms"

  size_full=$(bb_size_mb /bb/full) || return 1
  size_incr=$(bb_size_mb /bb/incr) || return 1
  size_combined=$(bb_size_mb /bb/combined) || return 1
  log "data size without pg_wal: full ${size_full} MB, incremental ${size_incr} MB, combined ${size_combined} MB"

  # 6. rows after the incremental backup but before the target (WAL only), the target, rows after it
  psql_p -c "INSERT INTO bb_marker (phase) SELECT 'wal' FROM generate_series(1, $ROWS)" >/dev/null || return 1
  sleep 3
  target=$(psql_p -c "SELECT clock_timestamp()") || return 1
  sleep 3
  psql_p -c "INSERT INTO bb_marker (phase) SELECT 'after' FROM generate_series(1, $ROWS)" >/dev/null || return 1
  lsn=$(psql_p -c "SELECT pg_switch_wal()") || return 1
  wait_until 120 "WAL up to $lsn archived" archived_past "$lsn" || return 1

  # 7. point-in-time restore of the combined backup
  log "restore target $target"
  out=$(bb_run none "$RESTORE_SCRIPT" sh "$target") || { FAILS+=("restore container failed"); return 1; }
  log "restored: $out"
  local ms_restore n_full n_incr n_wal n_after
  ms_restore=${out#ms=}; ms_restore=${ms_restore%% *}
  n_full=${out#*full=}; n_full=${n_full%% *}
  n_incr=${out#*incr=}; n_incr=${n_incr%% *}
  n_wal=${out#*wal=}; n_wal=${n_wal%% *}
  n_after=${out##*after=}
  EXTRA_JSON=$(jq -n -c --arg target "$target" --argjson rows "$ROWS" --argjson ballast "$BALLAST_ROWS" \
    --argjson full "${ms_full:-null}" --argjson incr "${ms_incr:-null}" --argjson combine "${ms_combine:-null}" \
    --argjson verify "${ms_verify:-null}" --argjson restore "${ms_restore:-null}" \
    --argjson sfull "${size_full:-null}" --argjson sincr "${size_incr:-null}" --argjson scomb "${size_combined:-null}" \
    --argjson rfull "${n_full:-null}" --argjson rincr "${n_incr:-null}" --argjson rwal "${n_wal:-null}" --argjson rafter "${n_after:-null}" \
    '{restore_target: $target, rows_per_phase: $rows, ballast_rows: $ballast,
      step_ms: {full: $full, incremental: $incr, combine: $combine, verify: $verify, restore: $restore},
      size_mb_without_wal: {full: $sfull, incremental: $sincr, combined: $scomb},
      restored: {full: $rfull, incremental: $rincr, wal: $rwal, after: $rafter}}') || return 1
  summary
  [ "$n_full" = "$ROWS" ] || { FAILS+=("restored $n_full rows written before the full backup, expected $ROWS"); return 1; }
  [ "$n_incr" = "$ROWS" ] || { FAILS+=("restored $n_incr rows written between full and incremental backup, expected $ROWS"); return 1; }
  [ "$n_wal" = "$ROWS" ] || { FAILS+=("restored $n_wal rows written after the incremental backup and before the target, expected $ROWS"); return 1; }
  [ "$n_after" = 0 ] || { FAILS+=("restored $n_after rows written after the target, expected 0"); return 1; }
}
revert() {
  local rc=0
  psql_p -c "DROP TABLE IF EXISTS bb_marker, bb_ballast" >/dev/null || rc=1
  docker rm -f "$BB_C" >/dev/null 2>&1 || true
  docker volume rm "$BB_VOL" >/dev/null 2>&1 || true
  resume_backups || rc=1
  return "$rc"
}
run_scenario basebackup-compare
