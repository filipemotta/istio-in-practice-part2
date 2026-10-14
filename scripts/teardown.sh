#!/usr/bin/env bash
# Removes everything the lab created: the kind cluster istio-p2 (and with it
# every namespace, addon and policy). Nothing else on the machine is touched.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "kind cluster ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" || true
note "done"
