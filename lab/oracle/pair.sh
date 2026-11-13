# The CDB19 Data Guard pair of the first slice (ADR 0008 decision 3) and the
# observer VM that runs the Collector. Sourced by scripts/*.sh.
# ssh aliases are the short host names; Oracle Net uses the lab.local names
# the broker configuration uses. SIDs equal db_unique_name and the default
# service name on both VMs (read 2026-11-13).
# shellcheck shell=bash disable=SC2034
PRIMARY_HOST=ora-au-lab
PRIMARY_SID=CDB19
STANDBY_HOST=ora-dg-stby
STANDBY_SID=CDB19_STBY
OBSERVER_HOST=ora-dg-obs
DOMAIN=lab.local
LISTENER_PORT=1521
# Oracle home on the observer VM (the observers' 19c home); used only to check
# the logins from the Collector's vantage point.
OBSERVER_ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
# Common users (ADR 0008 decision 4) and their profile.
MON_USER='C##OBENHUB_MON'
DG_USER='C##OBENHUB_DG'
MON_PROFILE='C##OBENHUB_MON'
