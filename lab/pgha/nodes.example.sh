# Copy to nodes.sh (untracked, gitignored) and edit: the addresses of this
# site. Sourced by scripts/*.sh and scenarios/lib.sh through lab/pgha/lab-config.sh.
# The values here are documentation-range examples (RFC 5737), not real hosts.
# shellcheck shell=bash disable=SC2034
# The three pgha VMs as name=IP; the names must equal the ids in targets.json.
NODES="pgha-1=192.0.2.16 pgha-2=192.0.2.17 pgha-3=192.0.2.18"
# The subnet of the VMs and of the box (allowed in pg_hba and the firewall).
SUBNET=192.0.2.0/24
# The address of this box on the lab LAN, the one the VMs route to; the
# telemetry gateway (lab/pgha/mon) listens there (checked by scripts/provision.sh).
GATEWAY_IP=192.0.2.11
# The only port the VMs reach on this box: the gateway Collector's OTLP/HTTP port.
GATEWAY_PORT=34318
