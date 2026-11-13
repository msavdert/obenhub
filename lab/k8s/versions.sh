# shellcheck shell=bash disable=SC2034
# Pinned versions for the kind lab; the one source of truth, sourced by scripts/.
# Read 2026-11-10. Renovate reads the '# renovate:' comments (renovate.json).

# kind cluster name; the kubectl context is kind-${KIND_CLUSTER}.
KIND_CLUSTER=obenhub

# kind node image: kind v0.33.0 release notes
# https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0 (tag and digest
# verified there). It should move together with kind (mise.k8s.toml): Renovate may
# propose a newer node image, and renovate.json holds back minor and major
# bumps. A node image not listed in the kind release notes is untested with
# that kind (assumption: patch releases of the same minor work).
# renovate: datasource=docker
KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed

# CloudNativePG release manifest at its release tag. The release's
# cnpg-<version>-checksums.txt lists only the kubectl-cnpg archives, not the
# manifest, so CNPG_MANIFEST_SHA256 is the sha256 of the manifest downloaded
# from CNPG_MANIFEST_URL on 2026-11-11 (the same bytes as the release asset
# cnpg-1.30.1.yaml). A new CNPG_VERSION needs a new sha256: up.sh fails until
# it is updated (`curl -fsSL "$CNPG_MANIFEST_URL" | sha256sum`, after reading
# the diff). The kubectl-cnpg plugin is pinned in mise.k8s.toml at the same
# version; scripts/check-tools.sh fails when they differ.
# renovate: datasource=github-releases depName=cloudnative-pg/cloudnative-pg extractVersion=^v(?<version>.+)$
CNPG_VERSION=1.30.1
CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml"
CNPG_MANIFEST_SHA256=37237f145d8138256ea25ae830f87759255665ff08f8d552fdd8224a5ec032fb

# PostgreSQL 18 operand: DefaultImageName at tag v1.30.1 of
# cloudnative-pg/cloudnative-pg is ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie;
# this pin is one minor release newer (18.7, released 2026-11-12, security fixes).
# The digest is the multi-arch index digest, read from the registry with
# `docker buildx imagetools inspect` on 2026-11-12.
# renovate: datasource=docker
PG_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.7-system-trixie@sha256:5a5dfbde88d5909fd4938189c141f53fb153f53c519f14907dce9e7c04baa153

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
