-- The monitoring users of the Oracle packs: the accounts the Collector's
-- oracledb receiver (C##OBENHUB_MON) and sql_query receivers (C##OBENHUB_DG)
-- log in with. The standalone form of lab/oracle/scripts/mon-lib.sh
-- (mon_sql), which provision.sh runs for the lab; scripts/check-oracle-user-sql.py
-- (mise run check) fails when the two grant lists differ.
--
-- Run it once per CDB, from the root container, as SYSDBA on an open primary
-- (a Data Guard standby gets both users by redo):
--   printf '%s\n%s\n' "$MON_PASSWORD" "$DG_PASSWORD" | sqlplus -s -L / as sysdba @monitoring-user.sql
-- The two ACCEPT commands read the passwords from standard input (a pipe: on a
-- terminal they would be echoed), so they are in neither a command line nor a
-- file. A password is 12 to 30 characters, letters and digits only (the script
-- checks; Oracle allows 30, ORA-00972).
-- The statements carry the passwords, as every CREATE USER does: an audit
-- policy or statement trace on this session records them.
-- Safe to run again: an existing user keeps its grants and gets the password
-- reset (the PostgreSQL role script does the same). Only a CDB is covered: the
-- accounts are common users (C## prefix, CONTAINER=ALL).
--
-- What it creates:
--   profile C##OBENHUB_MON  passwords never expire (an expired monitoring
--                           password is ORA-28001 at the next login, and the
--                           pooled sessions hide it until they restart)
--   C##OBENHUB_MON          CREATE SESSION and SELECT on the single views the
--                           oracledb receiver README lists (contrib v0.164.0,
--                           instance detection, metrics and per-PDB metrics),
--                           CONTAINER_DATA=ALL so that a root connection reads
--                           every container; no role, no SELECT ANY. ASM, the
--                           events (query samples) and the PDB-connection
--                           views are left out: the packs use none of them
--   C##OBENHUB_DG           SYSDG only, no other grant; why it is needed
--                           even without a standby: docs/guides/monitor/oracle.md

whenever sqlerror exit failure
whenever oserror exit failure
set feedback off verify off echo off serveroutput on
-- standard input that ends before both passwords are read is an OS error (exit
-- status 1); the sentinel below is a second guard: the check rejects it
define mon_pw = '!'
define dg_pw = '!'
accept mon_pw char
accept dg_pw char

-- The only statement that carries the passwords as text, on one line, before
-- any DDL; q'~...~' takes every character but the pair ~' literally. Everything
-- after it uses the bind variables.
variable mon_pw varchar2(200)
variable dg_pw varchar2(200)
begin :mon_pw := q'~&mon_pw~'; :dg_pw := q'~&dg_pw~'; end;
/

-- validate before any change: NULL (an empty line) and the sentinel fail too
begin
  if :mon_pw is null or :dg_pw is null
     or not regexp_like(:mon_pw, '^[A-Za-z0-9]{12,30}$')
     or not regexp_like(:dg_pw, '^[A-Za-z0-9]{12,30}$') then
    raise_application_error(-20002, 'two passwords of 12 to 30 letters and digits are read from standard input, one per line');
  end if;
end;
/

DECLARE
  n NUMBER;
  mon_pw CONSTANT VARCHAR2(30) := :mon_pw;
  dg_pw  CONSTANT VARCHAR2(30) := :dg_pw;
  PROCEDURE x(s VARCHAR2) IS BEGIN EXECUTE IMMEDIATE s; END;
  PROCEDURE ensure_user(u VARCHAR2, pw VARCHAR2) IS
  BEGIN
    SELECT COUNT(*) INTO n FROM dba_users WHERE username = u;
    IF n = 0 THEN
      x('CREATE USER "' || u || '" IDENTIFIED BY "' || pw || '" PROFILE "C##OBENHUB_MON" ACCOUNT UNLOCK CONTAINER=ALL');
      dbms_output.put_line('created user ' || u);
    ELSE
      x('ALTER USER "' || u || '" IDENTIFIED BY "' || pw || '" ACCOUNT UNLOCK CONTAINER=ALL');
      dbms_output.put_line('reset password of ' || u);
    END IF;
    x('ALTER USER "' || u || '" PROFILE "C##OBENHUB_MON" CONTAINER=ALL');
  END;
BEGIN
  IF SYS_CONTEXT('USERENV', 'CON_ID') <> '1' THEN
    raise_application_error(-20003, 'run this in the root container of a CDB (CON_ID 1)');
  END IF;
  SELECT COUNT(*) INTO n FROM v$database WHERE database_role = 'PRIMARY' AND open_mode = 'READ WRITE';
  IF n = 0 THEN
    raise_application_error(-20001, 'not an open primary: run it on the primary');
  END IF;
  SELECT COUNT(*) INTO n FROM dba_profiles WHERE profile = 'C##OBENHUB_MON';
  IF n = 0 THEN
    x('CREATE PROFILE "C##OBENHUB_MON" LIMIT PASSWORD_LIFE_TIME UNLIMITED CONTAINER=ALL');
    dbms_output.put_line('created profile C##OBENHUB_MON');
  END IF;
  x('ALTER PROFILE "C##OBENHUB_MON" LIMIT PASSWORD_LIFE_TIME UNLIMITED PASSWORD_GRACE_TIME UNLIMITED'
    || ' PASSWORD_REUSE_TIME UNLIMITED PASSWORD_REUSE_MAX UNLIMITED CONTAINER=ALL');
  ensure_user('C##OBENHUB_MON', mon_pw);
  ensure_user('C##OBENHUB_DG', dg_pw);
  x('GRANT CREATE SESSION TO "C##OBENHUB_MON" CONTAINER=ALL');
  -- grant list: GRANT SELECT ON SYS.<view>; scripts/check-oracle-user-sql.py reads these lines
  x('GRANT SELECT ON SYS.V_$INSTANCE TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$DATABASE TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$DATAFILE TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$SESSION TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$SYSSTAT TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$RESOURCE_LIMIT TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$OSSTAT TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$SGAINFO TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$CON_SYSSTAT TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$CON_SYSMETRIC TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.V_$CONTAINERS TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.DBA_TABLESPACES TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.DBA_DATA_FILES TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.DBA_TABLESPACE_USAGE_METRICS TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.CDB_TABLESPACE_USAGE_METRICS TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.CDB_TABLESPACES TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('GRANT SELECT ON SYS.CDB_DATA_FILES TO "C##OBENHUB_MON" CONTAINER=ALL');
  x('ALTER USER "C##OBENHUB_MON" SET CONTAINER_DATA=ALL CONTAINER=CURRENT');
  SELECT COUNT(*) INTO n FROM v$pwfile_users WHERE username = 'C##OBENHUB_DG' AND sysdg = 'TRUE';
  IF n = 0 THEN
    x('GRANT SYSDG TO "C##OBENHUB_DG" CONTAINER=ALL');
    dbms_output.put_line('granted SYSDG to C##OBENHUB_DG');
  END IF;
END;
/
exit
