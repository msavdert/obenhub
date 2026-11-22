# shellcheck shell=bash disable=SC2034
# Pins for the Helm install of the Collector (README.md in deploy/): sourced by
# the install commands there. Same chart and image as lab/k8s/versions.sh;
# scripts/check-deploy-pins.py (part of `mise run check`) fails when they
# differ, and Renovate reads the '# renovate:' comments (renovate.json).

# Collector Helm chart opentelemetry-collector, release tag
# opentelemetry-collector-<version> of open-telemetry/opentelemetry-helm-charts.
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-helm-charts extractVersion=^opentelemetry-collector-(?<version>.+)$
OTEL_CHART_VERSION=0.180.0
OTEL_CHART_REPO=https://open-telemetry.github.io/opentelemetry-helm-charts

# Collector contrib image, set explicitly in the values (the chart's appVersion
# is older).
# renovate: datasource=docker
OTELCOL_IMAGE=otel/opentelemetry-collector-contrib:0.165.0@sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea
