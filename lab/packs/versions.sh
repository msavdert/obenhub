# shellcheck shell=bash disable=SC2034
# Image used by every rule-test task of mise.toml (scripts/vmalert-unittest.sh
# sources this file). Renovate reads the '# renovate:' comment and moves tag
# and digest together (renovate.json, customManagers: tag@digest in lab shell
# scripts). The digest is the multi-arch index digest, read from the registry
# with `docker buildx imagetools inspect victoriametrics/vmalert-tool:v1.155.0`
# on 2026-11-12.
# renovate: datasource=docker
VMALERT_TOOL_IMAGE=victoriametrics/vmalert-tool:v1.155.0@sha256:b03d29d0a11b906a85879a6a4009c9d0a9d5a8b9a744ebb7dd3a7721f1e78f36
