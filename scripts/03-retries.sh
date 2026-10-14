#!/usr/bin/env bash
# Step 3: retries of payments-api -> fraud-check (sidecar mode), counted where
# they land: every request that reaches a fraud-check pod is one fortio log
# line, so "attempts" below is what fraud-check actually received.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

NS="payments"
reset_policies "${NS}"

step "No policy: the mesh already retries, but not an application 503"
wait_route "${NS}" '.[0].route.timeout == "0s"' || true
rp="$(policy_route "${NS}" | jq -c '.[0].route.retryPolicy | {numRetries, retryOn}')"
note "default retry policy pushed to the caller: ${rp}"
expect_eq "default: 2 retries on connection-level failures only" \
  '{"numRetries":2,"retryOn":"connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes"}' "${rp}"
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503")"; note "call -> ${r}"
expect_eq "fraud-check answers 503: the caller gets 503" "503" "$(cut -d' ' -f1 <<< "${r}")"
expect_eq "and it reached fraud-check exactly once (503 is not in the default retryOn)" "1" "$(attempts "${NS}" "${id}")"

step "Istio API: retries/virtualservice/fraud-check-retries.yaml (attempts 2, perTryTimeout 500ms, timeout 2s)"
apply_scenario "${REPO_ROOT}/retries/virtualservice/fraud-check-retries.yaml"
wait_route "${NS}" '.[0].route.retryPolicy.numRetries == 2 and .[0].route.timeout == "2s"'
note "pushed: $(policy_route "${NS}" | jq -c '.[0].route | {timeout, retryPolicy: (.retryPolicy | {numRetries, retryOn, perTryTimeout})}')"
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503")"; note "always-503 -> ${r}"
expect_eq "still 503 for the caller" "503" "$(cut -d' ' -f1 <<< "${r}")"
expect_eq "but fraud-check received 3 requests (1 + 2 retries)" "3" "$(attempts "${NS}" "${id}")"
log="$(access_log "${NS}" payments-api "${id}")"; note "caller access log: ${log:0:150}"
expect_match "response flag URX: retry limit exceeded" '" 503 URX ' "${log}"

id="$(run_id)"
r="$(call "${NS}" "/${id}?delay=1s")"; note "always-slow (1s) -> ${r}"
expect_eq "every try hits perTryTimeout (500ms): 504" "504" "$(cut -d' ' -f1 <<< "${r}")"
expect_between "after 3 tries of 500ms plus backoff, inside the 2s budget (ms)" 1450 2050 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
expect_eq "fraud-check received 3 requests and did 3 x 1s of work" "3" "$(attempts "${NS}" "${id}" 2)"

step "Flaky fraud-check (?status=503:50): what retries buy, and what they cost"
id="$(run_id)"
h="$(codes "${NS}" 100 "/${id}?status=503:50")"; note "100 calls -> ${h}"
ok="$(field 200 "${h}")"
expect_between "success rate with retries (without: ~50; expected ~87.5)" 75 98 "${ok}"
a="$(attempts "${NS}" "${id}")"
note "fraud-check received ${a} requests for 100 calls"
expect_between "load on fraud-check: ~1.75x the calls (expected 175)" 150 200 "${a}"

step "Silent error: client retries x mesh retries (curl --retry 2 on top of attempts: 2)"
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503" --retry 2 --retry-delay 0.2)"; note "one logical call -> ${r}"
expect_eq "the application sees one failure" "503" "$(cut -d' ' -f1 <<< "${r}")"
expect_eq "fraud-check received (1 + 2) x (1 + 2) = 9 requests" "9" "$(attempts "${NS}" "${id}")"

step "Silent error: HTTPRoute retry with the standard Gateway API CRDs (silent-errors/04-httproute-retry-standard-channel.yaml)"
reset_policies "${NS}"
f="${REPO_ROOT}/silent-errors/04-httproute-retry-standard-channel.yaml"
set +e
out="$(k apply -f "${f}" 2>&1)"; rc=$?
set -e
note "kubectl apply: ${out}"
expect_eq "strict field validation (kubectl default) rejects it" "1" "${rc}"
expect_match "with: unknown field spec.rules[0].retry" 'unknown field "spec.rules\[0\]\.retry"' "${out}"
out="$(k apply --validate=false -f "${f}" 2>&1)"; note "kubectl apply --validate=false: ${out}"
expect_eq "with validation off the route is created, retry silently dropped" '["backendRefs","matches","timeouts"]' \
  "$(k -n "${NS}" get httproute fraud-check -o json | jq -c '.spec.rules[0] | keys')"
wait_route "${NS}" '.[0].route.timeout == "2s"'
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=503")"; note "always-503 -> ${r}"
expect_eq "and fraud-check is called once: no retries" "1" "$(attempts "${NS}" "${id}")"

reset_policies "${NS}"
finish
