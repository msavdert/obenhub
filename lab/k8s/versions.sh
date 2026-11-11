# shellcheck shell=bash disable=SC2034
# Pinned versions for the kind lab; the one source of truth, sourced by scripts/.
# Read 2026-11-10. Renovate reads the '# renovate:' comments (renovate.json).

# kind cluster name; the kubectl context is kind-${KIND_CLUSTER}.
KIND_CLUSTER=obenhub

# kind node image: kind v0.33.0 release notes
# https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0 (tag and digest
# verified there). It moves with the kind release, so Renovate leaves it alone.
KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed

# CloudNativePG release manifest at its release tag.
# renovate: datasource=github-releases depName=cloudnative-pg/cloudnative-pg extractVersion=^v(?<version>.+)$
CNPG_VERSION=1.30.1
CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml"

# PostgreSQL 18 operand: DefaultImageName in pkg/versions/versions.go at tag
# v1.30.1 of cloudnative-pg/cloudnative-pg is
# ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie. The digest is the
# multi-arch index digest, read from the registry with
# `docker buildx imagetools inspect` on 2026-11-10.
# renovate: datasource=docker
PG_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie@sha256:48a0038fdd9672d12853d5300666b2592f97f9d34a993ea42e3ecb5a9a5e43e3

# Collector Helm chart opentelemetry-collector, release tag
# opentelemetry-collector-<version> of open-telemetry/opentelemetry-helm-charts
# (Chart.yaml version 0.178.3, appVersion 0.163.2, read 2026-11-10).
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-helm-charts extractVersion=^opentelemetry-collector-(?<version>.+)$
OTEL_CHART_VERSION=0.178.3
OTEL_CHART_REPO=https://open-telemetry.github.io/opentelemetry-helm-charts

# Collector contrib image: the version lab/pgha/versions.sh OTELCOL_VERSION and
# lab/pgha/mon/compose.yaml run (the chart's appVersion is older; the image is
# set explicitly). The digest is the multi-arch index digest, read from the
# registry with `docker buildx imagetools inspect` on 2026-11-10.
# renovate: datasource=docker
OTELCOL_IMAGE=otel/opentelemetry-collector-contrib:0.164.0@sha256:340c9ca6a36617084c6661bdc4f0fe92b7cda5a805d61673ec8db375fddc522b
