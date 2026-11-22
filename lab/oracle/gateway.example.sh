# Copy to gateway.sh (untracked, gitignored) and edit: where ora-dg-obs finds
# the telemetry gateway of lab/oracle/mon on this box. Sourced by scripts/*.sh
# through lab/pgha/lab-config.sh. The values here are documentation-range
# examples (RFC 5737), not real hosts.
# shellcheck shell=bash disable=SC2034
# The address of this box on the lab LAN, the one ora-dg-obs routes to.
GATEWAY_IP=192.0.2.11
# The one port ora-dg-obs reaches on this box: the gateway's OTLP/HTTP port.
GATEWAY_PORT=54318
