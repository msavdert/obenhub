-- The monitoring role of the PostgreSQL labs: the account the Collector's
-- postgresql receiver and the sql_query list (queries.yaml) log in with.
-- Run with psql by slice1 (primary and subscriber), stage3 and pgha, after the
-- caller has set the psql variable mon_pw (\getenv mon_pw OTEL_MONITOR_PASSWORD,
-- or \set on stdin): the password never appears in argv or in a file. The
-- caller also silences logging and pg_stat_statements for the session, because
-- these statements carry the password. lab/k8s declares the same role as a
-- CloudNativePG managed role (lab/k8s/cnpg/cluster.yaml). Safe to run again:
-- an existing role keeps its grants and gets the password reset.

-- no password in CREATE: the ALTER below sets it, whether the role is new or not
SELECT 'CREATE ROLE otel_monitor LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'otel_monitor') \gexec
SELECT format('ALTER ROLE otel_monitor WITH LOGIN PASSWORD %L', :'mon_pw') \gexec

-- read-only access to the statistics views and functions the queries use
GRANT pg_monitor TO otel_monitor;
-- the reserved connection slots: monitoring keeps working when the application
-- has used up max_connections (the connections-exhausted scenario)
-- (the role exists from PostgreSQL 16; on 15 there is nothing to grant, found by
-- scripts/test-pack-sql.py)
SELECT 'GRANT pg_use_reserved_connections TO otel_monitor'
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_use_reserved_connections') \gexec
-- bounds every monitoring query to 5 s
ALTER ROLE otel_monitor SET statement_timeout = '5s';
