#!/usr/bin/env bash
# Step 7: the same policies in ambient mode. ztunnel is L4 only; the waypoint
# of payments-ambient (ambient/waypoint.yaml, created in step 1) applies
# timeouts, retries, connection pool, outlier detection and faults. Counting
# works the same way: fortio logs every request that reaches fraud-check, and
# the stats are read from the waypoint instead of a sidecar.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/04-circuit-breaking.sh"
assert_lab_context

NS="payments-ambient"
# fc_waypoint -> the waypoint ztunnel uses for fraud-check ("None" without one)
fc_waypoint() {
  ictl ztunnel-config service --service-namespace "${NS}" | awk '$2 == "fraud-check" { print $4 }'
}
reset_policies "${NS}"

step "The waypoint is in the path"
expect_eq "namespace uses waypoint" "waypoint" "$(k get ns "${NS}" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')"
expect_eq "waypoint Programmed" "True" "$(k -n "${NS}" get gateway waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"

step "Timeout through the waypoint: ambient/timeout-httproute.yaml (Gateway API, Beta on waypoints)"
apply_scenario "${REPO_ROOT}/ambient/timeout-httproute.yaml"
wait_route "${NS}" '.[0].route.timeout == "1s"'
note "ResolvedWaypoints: $(k -n "${NS}" get httproute fraud-check -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedWaypoints")].status}')"
r="$(call "${NS}" '/a-timeout?delay=3s')"; note "call -> ${r}"
expect_eq "504" "504" "${r%% *}"
expect_between "after ~1s (ms)" 950 1600 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
expect_match "the waypoint logs UT" '" 504 UT response_timeout ' "$(access_log "${NS}" waypoint a-timeout)"

step "Silent error: the same HTTPRoute without the waypoint (label istio.io/use-waypoint removed)"
k label ns "${NS}" istio.io/use-waypoint- >/dev/null
wait_for 60 "None" fc_waypoint || true
note "ztunnel: fraud-check waypoint = $(fc_waypoint)"
note "HTTPRoute Accepted=$(k -n "${NS}" get httproute fraud-check -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'), ResolvedWaypoints: $(k -n "${NS}" get httproute fraud-check -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedWaypoints")].message}')"
expect_eq "the HTTPRoute is still Accepted" "True" \
  "$(k -n "${NS}" get httproute fraud-check -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
r="$(call "${NS}" '/a-nowaypoint?delay=3s')"; note "call -> ${r}"
expect_eq "and ignored: 200 after the full delay" "200" "${r%% *}"
expect_between "(ms)" 2900 4500 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
k label ns "${NS}" istio.io/use-waypoint=waypoint --overwrite >/dev/null
wait_for 60 "waypoint" fc_waypoint || true
expect_eq "label restored: ztunnel sends fraud-check through the waypoint again" "waypoint" "$(fc_waypoint)"

step "Retries through the waypoint: ambient/retries-virtualservice.yaml (VirtualService, Alpha on waypoints)"
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/ambient/retries-virtualservice.yaml"
wait_route "${NS}" '.[0].route.retryPolicy.numRetries == 2 and .[0].route.timeout == "2s"'
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503")"; note "always-503 -> ${r}"
expect_eq "fraud-check received 3 requests" "3" "$(attempts "${NS}" "${id}")"
expect_match "the waypoint logs URX" '" 503 URX ' "$(access_log "${NS}" waypoint "${id}")"
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503" --retry 2 --retry-delay 0.2)"; note "with curl --retry 2 -> ${r}"
expect_eq "client x waypoint retries: 9 requests at fraud-check" "9" "$(attempts "${NS}" "${id}")"

step "Fault one hop below, through the same waypoint: ambient/fault-risk-score-abort.yaml"
apply_scenario "${REPO_ROOT}/ambient/fault-risk-score-abort.yaml"
wait_json 90 '[.[] | select(.name == "inbound-vip|8080|http|risk-score.payments-ambient.svc.cluster.local") | .virtualHosts[].routes[].typedPerFilterConfig["envoy.filters.http.fault"] != null] == [true]' \
  ictl proxy-config route deploy/waypoint -n "${NS}" -o json
wait_json 90 '[.[] | select(.name == "inbound-vip|8090|http|fraud-check.payments-ambient.svc.cluster.local") | .virtualHosts[].routes[].route.retryPolicy.numRetries] == [2]' \
  ictl proxy-config route deploy/waypoint -n "${NS}" -o json
id="$(run_id)"
r="$(k -n "${NS}" exec deploy/payments-api -c app -- curl -s -o /dev/null -w '%{http_code}' "http://fraud-check:8090/${id}?status=200")"
note "payments-api -> fraud-check:8090 -> risk-score -> ${r}"
expect_eq "503 after the retries" "503" "${r}"
expect_eq "the waypoint injected the abort 3 times (1 + 2 retries)" "3" \
  "$(proxy_log_count "${NS}" gateway.networking.k8s.io/gateway-name=waypoint "${id}" '" 503 FI fault_filter_abort ')"
expect_eq "risk-score was never called" "0" "$(k -n "${NS}" logs deploy/risk-score -c fortio --since=10m | grep -c "/${id}" || true)"

check_connection_pool "${NS}" "${REPO_ROOT}/ambient/connection-pool.yaml"
check_outlier_detection "${NS}" "${REPO_ROOT}/ambient/outlier-detection.yaml"
finish
