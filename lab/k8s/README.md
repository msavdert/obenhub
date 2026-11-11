# lab/k8s

A kind cluster (one control plane, three workers, cluster name `obenhub`)
running the CloudNativePG operator and one `Cluster` named `pg` in namespace
`obenhub`: three PostgreSQL 18 instances, one per worker (required pod
anti-affinity on `kubernetes.io/hostname`), 1Gi each on kind's default
StorageClass, database `app`. No monitoring yet.

Needs Docker, `kind` 0.33.0 (the release whose node image `versions.sh`
pins), `kubectl`, and `fs.inotify.max_user_watches` >= 524288
and `max_user_instances` >= 512 ([kind known issues][kind-ki]); `up.sh` stops
without changing sysctls if they are lower.

```sh
lab/k8s/scripts/up.sh     # idempotent; about 4 minutes from nothing
lab/k8s/scripts/down.sh   # deletes the kind cluster and all its data
```

All versions are pinned in `versions.sh`, with the source of each. The kind
and Cluster manifests hold a `${...}` placeholder that `up.sh` fills from it.
The cluster name is `KIND_CLUSTER` in `versions.sh`; every kubectl call uses
the context `kind-<name>`.

## Checked on 2026-11-10

`up.sh` from nothing: kind v0.33.0, node `v1.36.4`, CloudNativePG 1.30.1,
operand `postgresql:18.6-system-trixie`. Result:

- pods `pg-1`, `pg-2`, `pg-3` on `obenhub-worker`, `-worker2`, `-worker3`
- Cluster `Cluster in healthy state`, primary `pg-1`, 3 ready instances
- `show server_version` returns `18.6`; `pg_stat_replication` on the primary
  lists `pg-2` and `pg-3` as `streaming`
- a row inserted with `psql -h pg-rw` inside `pg-3` was served by the
  primary's pod IP with `pg_is_in_recovery()` false, and `pg-3` (in
  recovery) then read it back
- a second `up.sh` changes nothing and returns in about 2 seconds

[kind-ki]: https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
