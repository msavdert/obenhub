# The telemetry gateway of lab/oracle/mon: the one port ora-dg-obs reaches on
# this box. Sourced by scripts/pki.sh and scripts/gen-mon-env.sh.
# shellcheck shell=bash disable=SC2034
# Assumption: GATEWAY_IP is the address of this box on the lab LAN and
# ora-dg-obs routes to it (same address as lab/pgha/nodes.sh).
GATEWAY_IP=10.0.0.11
GATEWAY_PORT=54318
