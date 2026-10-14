#!/usr/bin/env bash
# Step 2: the time budget of payments-api -> fraud-check (sidecar mode).
# No timeout by default; a route timeout in both APIs; a mesh timeout looser
# than the application's, which does nothing; the x-envoy-upstream-rq-timeout-ms
# header, which a default 1.31 sidecar strips; and a delay injected on the same
# route as the timeout, which the timeout does not cover.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

NS="payments"
reset_policies "${NS}"

step "No policy: fraud-check takes 3s (?delay=3s), the mesh waits as long as it takes"
wait_route "${NS}" '.[0].route.timeout == "0s"' || true
note "pushed route timeout: $(policy_route "${NS}" | jq -r '.[0].route.timeout') (0s = disabled)"
r="$(call "${NS}" '/t-default?delay=3s')"; note "call -> ${r}"
expect_eq "no timeout by default: 200" "200" "$(cut -d' ' -f1 <<< "${r}")"
expect_between "and the caller waited the full 3s (ms)" 2900 4500 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"

step "Istio API: timeouts/virtualservice/fraud-check-timeout.yaml (timeout: 1s)"
apply_scenario "${REPO_ROOT}/timeouts/virtualservice/fraud-check-timeout.yaml"
wait_route "${NS}" '.[0].route.timeout == "1s"'
id="$(run_id)"
r="$(call "${NS}" "/${id}?delay=3s")"; note "call -> ${r}"
expect_eq "VirtualService timeout: 504" "504" "$(cut -d' ' -f1 <<< "${r}")"
expect_between "after ~1s (ms)" 950 1600 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
log="$(access_log "${NS}" payments-api "${id}")"; note "caller access log: ${log:0:160}"
expect_match "caller's proxy logs response flag UT (upstream request timeout)" '" 504 UT response_timeout ' "${log}"
sleep 3
expect_eq "fraud-check still did the full 3s of work and answered 200 to nobody" "1" "$(served "${NS}" "${id}" 200)"

step "Gateway API: timeouts/gateway-api/fraud-check-timeout.yaml (timeouts.request: 1s)"
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/timeouts/gateway-api/fraud-check-timeout.yaml"
wait_route "${NS}" '.[0].route.timeout == "1s"'
note "HTTPRoute Accepted: $(k -n "${NS}" get httproute fraud-check -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
r="$(call "${NS}" '/t-httproute?delay=3s')"; note "call -> ${r}"
expect_eq "HTTPRoute timeouts.request: 504" "504" "$(cut -d' ' -f1 <<< "${r}")"
expect_between "after ~1s (ms)" 950 1600 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"

step "Silent error: mesh timeout (5s) looser than the application timeout (curl --max-time 2)"
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/silent-errors/01-vs-timeout-looser-than-app.yaml"
wait_route "${NS}" '.[0].route.timeout == "5s"'
id="$(run_id)"
r="$(call "${NS}" "/${id}?delay=3s" --max-time 2)"; note "call -> ${r} (code, seconds, curl exit)"
expect_eq "the application gave up first: no HTTP status, curl exit 28" "000 28" "$(cut -d' ' -f1,3 <<< "${r}")"
expect_between "at its own 2s (ms)" 1950 2600 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
log="$(access_log "${NS}" payments-api "${id}")"; note "caller access log: ${log:0:160}"
expect_match "the mesh logs a downstream disconnect (DC), not its timeout (UT)" '" 0 DC ' "${log}"

step "x-envoy-upstream-rq-timeout-ms from the application, with the 1s route timeout"
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/timeouts/virtualservice/fraud-check-timeout.yaml"
wait_route "${NS}" '.[0].route.timeout == "1s"'
r="$(call "${NS}" '/t-header?delay=3s' -H 'x-envoy-upstream-rq-timeout-ms: 300')"; note "header 300ms -> ${r}"
expect_between "the header does not shorten the timeout: still ~1s (ms)" 950 1600 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
r="$(call "${NS}" '/t-header?delay=3s' -H 'x-envoy-upstream-rq-timeout-ms: 5000')"; note "header 5000ms -> ${r}"
expect_eq "nor lengthen it: 504" "504" "$(cut -d' ' -f1 <<< "${r}")"
seen="$(k -n "${NS}" exec deploy/payments-api -c app -- curl -s -H 'x-envoy-upstream-rq-timeout-ms: 300' "${FRAUD_URL}/debug" | grep -ci 'x-envoy-upstream-rq-timeout-ms' || true)"
expect_eq "the sidecar strips it before the request leaves (fraud-check /debug sees it 0 times)" "0" "${seen}"
hcm="$(ictl proxy-config listener deploy/payments-api -n "${NS}" --port 8080 -o json \
  | jq -c '[.. | objects | select(has("useRemoteAddress")) | {useRemoteAddress, internalAddressConfig}] | unique')"
note "outbound HTTP connection manager: ${hcm}"
expect_eq "no internal address config: every caller is external, x-envoy-* headers are not trusted" \
  '[{"useRemoteAddress":false,"internalAddressConfig":null}]' "${hcm}"

step "Silent error: delay injected on the same route as the timeout (silent-errors/02-vs-fault-delay-same-route.yaml)"
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/silent-errors/02-vs-fault-delay-same-route.yaml"
wait_route "${NS}" '.[0].route.timeout == "1s" and (.[0].typedPerFilterConfig["envoy.filters.http.fault"] != null)'
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=200")"; note "call -> ${r}"
expect_eq "the 1s timeout never fires: 200" "200" "$(cut -d' ' -f1 <<< "${r}")"
expect_between "after the full 3s delay (ms)" 2900 4500 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
log="$(access_log "${NS}" payments-api "${id}")"; note "caller access log: ${log:0:160}"
expect_match "response flag DI (delay injected), no UT" '" 200 DI ' "${log}"

reset_policies "${NS}"
finish
