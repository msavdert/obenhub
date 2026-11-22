# Copy to pair.sh (untracked, gitignored) and edit: the CDB19 Data Guard pair
# (ADR 0008 decision 3) and the observer VM that runs the Collector, as this
# site names them. Sourced by scripts/*.sh and scenarios/lib.sh through
# lab/pgha/lab-config.sh. The host names, SIDs and domain below are the ones
# the tracked targets.json and files/otelcol-*.yaml name; only the shape is an
# example, change them together with those files.
# shellcheck shell=bash disable=SC2034
# ssh alias of the primary VM.
PRIMARY_HOST=ora-au-lab
# SID of the primary (equals db_unique_name and the default service name).
PRIMARY_SID=CDB19
# ssh alias of the standby VM.
STANDBY_HOST=ora-dg-stby
# SID of the standby (equals db_unique_name and the default service name).
STANDBY_SID=CDB19_STBY
# ssh alias of the observer VM that runs the Collector.
OBSERVER_HOST=ora-dg-obs
# DNS domain the broker configuration uses for the Oracle Net host names.
DOMAIN=lab.local
# Listener port on both database VMs.
LISTENER_PORT=1521
# Oracle home on the observer VM (a 19c home), used only to check the logins
# from the Collector's vantage point.
OBSERVER_ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
# The common monitoring user (ADR 0008 decision 4).
MON_USER='C##OBENHUB_MON'
# The common Data Guard user.
DG_USER='C##OBENHUB_DG'
# The profile of the monitoring user.
MON_PROFILE='C##OBENHUB_MON'
