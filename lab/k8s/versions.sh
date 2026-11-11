# shellcheck shell=bash
# Pinned versions for the kind lab; the one source of truth, sourced by scripts/.
# Read 2026-11-10.

# kind cluster name; the kubectl context is kind-${KIND_CLUSTER}.
export KIND_CLUSTER="obenhub"

# kind node image: kind v0.33.0 release notes
# https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0 (tag and digest verified there).
export KIND_NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"

# CloudNativePG release manifest at its release tag.
export CNPG_VERSION="1.30.1"
export CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml"

# PostgreSQL 18 operand: DefaultImageName in pkg/versions/versions.go at tag
# v1.30.1 of cloudnative-pg/cloudnative-pg is
# ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie. The digest is the
# multi-arch index digest, read from the registry with
# `docker buildx imagetools inspect` on 2026-11-10.
export PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie@sha256:48a0038fdd9672d12853d5300666b2592f97f9d34a993ea42e3ecb5a9a5e43e3"
