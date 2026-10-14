#!/usr/bin/env bash
# Regenerates apps/payments-ambient.yaml from apps/payments-sidecar.yaml: same
# workloads, namespace payments-ambient, ambient data plane label.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed -e "1,2c\\
# Ambient-mode namespace: no sidecar; the node's ztunnel carries the traffic\\
# (L4, mTLS) and the waypoint in ambient/ applies the L7 policies." \
    -e 's/^    istio-injection: enabled$/    istio.io\/dataplane-mode: ambient/' \
    -e 's/^  namespace: payments$/  namespace: payments-ambient/' \
    -e 's/^  name: payments$/  name: payments-ambient/' \
    -e "s/ Both share the pod's sidecar\.$//" \
    "${REPO_ROOT}/apps/payments-sidecar.yaml" > "${REPO_ROOT}/apps/payments-ambient.yaml"
