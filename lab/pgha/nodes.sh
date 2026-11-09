# The three pgha VMs: hostname=IP. Sourced by scripts/*.sh.
# shellcheck shell=bash disable=SC2034
NODES="pgha-1=10.0.0.16 pgha-2=10.0.0.17 pgha-3=10.0.0.18"
SUBNET=10.0.0.0/24
# The telemetry gateway (lab/pgha/mon): the only port the VMs reach on this
# box. GATEWAY_IP is the address of the box on the lab LAN (assumption: it is
# the address the VMs route to; checked by scripts/provision.sh).
GATEWAY_IP=10.0.0.11
GATEWAY_PORT=34318
