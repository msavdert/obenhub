# shellcheck shell=bash disable=SC2034
# Image used by every rule-test task of mise.toml (scripts/vmalert-unittest.sh
# sources this file). Renovate reads the '# renovate:' comment and moves tag
# and digest together (renovate.json, customManagers: tag@digest in lab and
# pack shell scripts). The digest is the multi-arch index digest, read from the registry
# with `docker buildx imagetools inspect victoriametrics/vmalert-tool:v1.155.0`
# on 2026-11-12.
# renovate: datasource=docker
VMALERT_TOOL_IMAGE=victoriametrics/vmalert-tool:v1.156.0@sha256:5db1f962282311fe37212711fce72d55983a49a627c632feb38b318d949920fa
