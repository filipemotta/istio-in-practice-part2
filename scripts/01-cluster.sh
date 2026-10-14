#!/usr/bin/env bash
# Step 1: kind cluster, Gateway API CRDs (standard channel), Istio with the
# ambient profile (istiod + istio-cni + ztunnel), the observability addons of
# the Istio release (Prometheus, Grafana, Jaeger, Kiali), tracing, the alert
# rules of observability/alerts.yaml, and the payments workloads in a sidecar namespace and an ambient namespace.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_clis

step "kind cluster ${CLUSTER_NAME}"
if grep -qx "${CLUSTER_NAME}" <<< "$(kind get clusters 2>/dev/null)"; then
  note "already exists"
else
  kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml"
fi
assert_lab_context
k get nodes -o wide

step "Gateway API ${GATEWAY_API_VERSION} CRDs, standard channel"
k apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
k get crd -l gateway.networking.k8s.io/channel=standard \
  -o custom-columns='CRD:.metadata.name,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version'

step "Istio ${ISTIO_VERSION}, ambient profile (istio/install.yaml)"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml"
k -n istio-system get pods -o wide

step "Observability addons from the Istio ${ISTIO_VERSION} release (samples/addons)"
for addon in prometheus grafana jaeger kiali; do
  k apply -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/${addon}.yaml" >/dev/null
done
for d in prometheus grafana jaeger kiali; do
  k -n istio-system rollout status "deploy/${d}" --timeout=300s
done
apply_scenario "${REPO_ROOT}/observability/telemetry.yaml"
note "observability/alerts.yaml -> ConfigMap istio-system/prometheus, key alerting_rules.yml"
load_alert_rules

step "payments workloads: sidecar namespace and ambient namespace"
k apply -f "${REPO_ROOT}/apps/payments-sidecar.yaml"
k apply -f "${REPO_ROOT}/apps/payments-ambient.yaml"
for ns in payments payments-ambient; do
  for d in payments-api fraud-check risk-score; do
    k -n "${ns}" rollout status "deploy/${d}" --timeout=300s
  done
done

step "Waypoint for payments-ambient (ambient/waypoint.yaml) + namespace label"
apply_scenario "${REPO_ROOT}/ambient/waypoint.yaml"
k -n payments-ambient wait --for=condition=Programmed gateway/waypoint --timeout=180s
k -n payments-ambient rollout status deploy/waypoint --timeout=180s
k label ns payments-ambient istio.io/use-waypoint=waypoint --overwrite
k get pods -n payments -o wide
k get pods -n payments-ambient -o wide

step "Checks"
expect_eq "istiod ready" "1" "$(k -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}')"
nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
expect_eq "one ztunnel per node" "${nodes}" "$(k -n istio-system get ds ztunnel -o jsonpath='{.status.numberReady}')"
expect_eq "Gateway API CRDs from bundle ${GATEWAY_API_VERSION}, standard" "${GATEWAY_API_VERSION}/standard" \
  "$(k get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}/{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')"
for d in prometheus grafana jaeger kiali; do
  expect_eq "addon ${d} ready" "1" "$(k -n istio-system get deploy "${d}" -o jsonpath='{.status.readyReplicas}')"
done
# The kubelet refreshes the mounted ConfigMap with a delay; the reloader then reloads.
wait_for 240 "$(alert_rule_names)" loaded_alert_rules || true
expect_eq "Prometheus loaded the alert rules of observability/alerts.yaml" "$(alert_rule_names)" "$(loaded_alert_rules)"
expect_eq "mesh config: outbound traffic policy is ALLOW_ANY" "ALLOW_ANY" \
  "$(k -n istio-system get cm istio -o jsonpath='{.data.mesh}' | yq '.outboundTrafficPolicy.mode')"
expect_eq "payments-api (sidecar ns) runs app + load + istio-proxy" "app,load,istio-proxy" \
  "$(k -n payments get pod -l app=payments-api -o json | jq -r '.items[0] | [(.spec.initContainers[] | select(.name == "istio-proxy") | .name), .spec.containers[].name] | sort_by(. == "istio-proxy") | join(",")')"
expect_eq "fraud-check (sidecar ns): 2 ready replicas" "2" "$(k -n payments get deploy fraud-check -o jsonpath='{.status.readyReplicas}')"
expect_eq "fraud-check (ambient ns): 2 ready replicas" "2" "$(k -n payments-ambient get deploy fraud-check -o jsonpath='{.status.readyReplicas}')"
expect_eq "ambient payments-api has no injected proxy" "app,load" \
  "$(k -n payments-ambient get pod -l app=payments-api -o jsonpath='{.items[0].spec.containers[*].name}' | tr ' ' ',')"
expect_match "ztunnel sends fraud-check traffic (ambient) through the waypoint" \
  'fraud-check +[0-9.]+ +waypoint' "$(ictl ztunnel-config service --service-namespace payments-ambient)"
r="$(call payments /warmup?status=200)"
expect_eq "payments-api -> fraud-check answers 200 (sidecar)" "200" "${r%% *}"
r="$(call payments-ambient /warmup?status=200)"
expect_eq "payments-api -> fraud-check answers 200 (ambient)" "200" "${r%% *}"
finish
