#!/usr/bin/env bash
# Step 4: the two things called "circuit breaker" (sidecar mode).
# connectionPool limits concurrency and answers 503 on overflow;
# outlierDetection ejects an endpoint that keeps failing, if maxEjectionPercent
# lets it. Shared with step 7 (ambient) through check_connection_pool and
# check_outlier_detection below.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

# load <ns> <run id> -> "200=.. 503=.." from 60 calls, 6 concurrent, each
# taking 200ms at fraud-check (fortio load in payments-api's "load" container)
load() {
  k -n "$1" exec deploy/payments-api -c load -- fortio load -c 6 -qps 0 -n 60 -loglevel Warning \
    "${FRAUD_URL}/$2?delay=200ms" 2>&1 \
    | awk '/^Code / { printf "%s%s=%s", (n++ ? " " : ""), $2, $4 }'
}

# probe_load <run id> <fortio load args...> -> "200=.. 503=.." of calls from
# stats-probe (observability/stats-probe.yaml), the caller whose sidecar keeps
# Istio's default stats inclusion list (no proxyStatsMatcher).
probe_load() {
  local id="$1"; shift
  k -n payments exec deploy/stats-probe -c load -- fortio load -qps 0 -loglevel Warning "$@" \
    "${FRAUD_URL}/${id}" 2>&1 \
    | awk '/^Code / { printf "%s%s=%s", (n++ ? " " : ""), $2, $4 }'
}
# probe_cluster_stats <deployment> -> number of Envoy stats of the fraud-check
# cluster on that sidecar whose name matches the regex
probe_cluster_stats() {
  k -n payments exec "deploy/$1" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null \
    | grep -F "cluster.$(policy_cluster payments);." | grep -Ec -- "$2" || true
}

# check_connection_pool <ns> <connection-pool.yaml>
check_connection_pool() {
  local ns="$1" file="$2" id h o0 o1 c503
  step "[${ns}] Control: the same load without any DestinationRule"
  reset_policies "${ns}"
  wait_cluster "${ns}" '.circuitBreakers.thresholds[0].maxConnections == 4294967295' || true
  id="$(run_id)"; h="$(load "${ns}" "${id}")"; note "60 calls, 6 concurrent -> ${h}"
  expect_eq "no policy: all 60 succeed" "60" "$(field 200 "${h}")"

  step "[${ns}] connectionPool: ${file#"${REPO_ROOT}"/} (maxConnections 2, http1MaxPendingRequests 1)"
  apply_scenario "${file}"
  wait_cluster "${ns}" '.circuitBreakers.thresholds[0].maxConnections == 2 and .circuitBreakers.thresholds[0].maxPendingRequests == 1'
  o0="$(cstat "${ns}" upstream_rq_pending_overflow)"
  id="$(run_id)"; h="$(load "${ns}" "${id}")"; note "60 calls, 6 concurrent -> ${h}"
  c503="$(field 503 "${h}")"
  expect_between "overflow: part of the calls get 503" 10 55 "${c503}"
  o1="$(cstat "${ns}" upstream_rq_pending_overflow)"
  note "upstream_rq_pending_overflow on $(policy_proxy "${ns}"): ${o0} -> ${o1}"
  expect_eq "each 503 is one upstream_rq_pending_overflow" "${c503}" "$((o1 - o0))"
  expect_eq "the 503s never reached fraud-check: it served exactly the 200s" "$(field 200 "${h}")" "$(served "${ns}" "${id}" 200)"
  expect_eq "and fraud-check returned no 503 at all" "0" "$(served "${ns}" "${id}" 503)"

  [ "${ns}" = "payments" ] || return 0
  step "[${ns}] The same overflow from stats-probe, a sidecar without proxyStatsMatcher"
  id="$(run_id)"; h="$(probe_load "${id}?delay=200ms" -c 6 -n 60)"; note "stats-probe, 60 calls, 6 concurrent -> ${h}"
  expect_between "the connectionPool works the same: part of its calls get 503" 10 55 "$(field 503 "${h}")"
  note "fraud-check cluster stats on stats-probe: $(probe_cluster_stats stats-probe .) ; on payments-api: $(probe_cluster_stats payments-api .)"
  expect_eq "stats-probe's Envoy has no upstream_rq_pending_overflow for fraud-check (not even in pilot-agent request GET stats)" \
    "0" "$(probe_cluster_stats stats-probe 'upstream_rq_pending_overflow')"
  expect_eq "payments-api's Envoy has it (proxyStatsMatcher of istio/install.yaml)" \
    "1" "$(probe_cluster_stats payments-api '\.upstream_rq_pending_overflow: ')"
}

# observe_degraded <ns>: what Prometheus and Kiali show while the degraded
# replica is failing and nothing ejects it. Keeps a trickle of calls going:
# rate() ignores the first value of a new series, and the outlier counters
# disappear when the next DestinationRule rebuilds the cluster.
observe_degraded() {
  local ns="$1" c v=0 edges="" deadline=$((SECONDS + 120))
  c="$(policy_cluster "${ns}")"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    codes "${ns}" 10 "/o$(run_id)" >/dev/null
    v="$(prom_value "max(envoy_cluster_outlier_detection_ejections_overflow{cluster_name=\"${c}\", pod=~\"payments-api-.*\"})")"
    edges="$(svc_get istio-system kiali:20001 "/kiali/api/namespaces/graph?namespaces=${ns}&graphType=workload&duration=120s" \
      | jq -c '(.elements.nodes | map({key: .data.id, value: (.data.workload // .data.service // "?")}) | from_entries) as $n
        | [.elements.edges[].data | {from: $n[.source], to: $n[.target], err: (.traffic.rates.httpPercentErr // "0")}]')"
    if [ "${v}" -ge 1 ] && grep -Eq '"to":"fraud-check-degraded","err":"[1-9]' <<< "${edges}"; then break; fi
    sleep 5
  done
  note "Prometheus envoy_cluster_outlier_detection_ejections_overflow{cluster_name=\"${c}\"} = ${v}"
  jq -r '.[] | "      Kiali: \(.from) -> \(.to): \(.err)% errors"' <<< "${edges:-[]}"
  expect_between "Prometheus sees the skipped ejections (proxyStatsMatcher exports the counter)" 1 100000 "${v}"
  expect_match "Kiali shows the degraded replica failing" '"from":"payments-api","to":"fraud-check-degraded","err":"[1-9]' "${edges}"
}

# check_outlier_detection <ns> <outlier-detection.yaml> [<default.yaml> <30.yaml>]
# The two silent-error files are optional (step 7 runs only the working one).
check_outlier_detection() {
  local ns="$1" ok="$2" def="${3:-}" thirty="${4:-}" f id h e0 v0 ready
  step "[${ns}] Break one fraud-check replica: fraud-check-degraded answers 503, readiness still passes"
  reset_policies "${ns}"
  k -n "${ns}" scale deploy/fraud-check-degraded --replicas=1 >/dev/null
  k -n "${ns}" rollout status deploy/fraud-check-degraded --timeout=180s >/dev/null
  ready="$(k -n "${ns}" get pod -l variant=degraded -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')"
  expect_eq "the degraded pod is Ready: Kubernetes keeps it in the Service" "True" "${ready}"
  expect_eq "fraud-check has 3 endpoints" "3" \
    "$(k -n "${ns}" get endpointslice -l kubernetes.io/service-name=fraud-check -o json | jq '[.items[].endpoints[] | select(.conditions.ready)] | length')"
  # The Pod is Ready before every proxy has its endpoint: wait for the policy proxy.
  wait_for 90 "3" sh -c "istioctl --context '${KUBE_CONTEXT}' proxy-config endpoint deploy/$(policy_proxy "${ns}") -n '${ns}' --cluster '$(policy_cluster "${ns}")' | grep -c HEALTHY" || true
  expect_eq "the $(policy_proxy "${ns}") proxy sees 3 healthy fraud-check endpoints" "3" \
    "$(ictl proxy-config endpoint "deploy/$(policy_proxy "${ns}")" -n "${ns}" --cluster "$(policy_cluster "${ns}")" | grep -c HEALTHY)"
  # Listed is not yet used: right after the scale-up the first connections to
  # the new endpoint can fail and the default retry (connect-failure, other
  # host) hides it. Call until the degraded replica has answered at least once.
  local warm deadline=$((SECONDS + 90))
  until [ "$(served "${ns}" "${warm:-none}" 503)" -ge 1 ] || [ "${SECONDS}" -ge "${deadline}" ]; do
    warm="w$(run_id)"; codes "${ns}" 6 "/${warm}" >/dev/null; sleep 2
  done
  id="$(run_id)"; h="$(codes "${ns}" 60 "/${id}")"; note "no policy, 60 calls -> ${h}"
  expect_between "about 1 in 3 calls fail" 10 30 "$(field 503 "${h}")"

  for f in ${def:+"${def}"} ${thirty:+"${thirty}"}; do
    step "[${ns}] Silent error: ${f#"${REPO_ROOT}"/}"
    reset_policies "${ns}"
    apply_scenario "${f}"
    if [ "${f}" = "${def}" ]; then
      wait_cluster "${ns}" '.outlierDetection.consecutive5xx == 3 and (.outlierDetection.maxEjectionPercent == null)'
    else
      wait_cluster "${ns}" '.outlierDetection.maxEjectionPercent == 30'
    fi
    e0="$(cstat "${ns}" outlier_detection.ejections_enforced_total)"
    v0="$(cstat "${ns}" outlier_detection.ejections_overflow)"
    id="$(run_id)"; h="$(codes "${ns}" 60 "/${id}")"; note "60 calls -> ${h}"
    expect_between "nothing is ejected: still about 1 in 3 calls fail" 10 30 "$(field 503 "${h}")"
    expect_eq "ejections_enforced_total did not move" "0" "$(( $(cstat "${ns}" outlier_detection.ejections_enforced_total) - e0 ))"
    expect_between "ejections_overflow counts the ejections it skipped" 1 30 "$(( $(cstat "${ns}" outlier_detection.ejections_overflow) - v0 ))"
    if [ "${f}" = "${def}" ] && [ "${ns}" = "payments" ]; then
      h="$(probe_load "p$(run_id)" -c 1 -n 60)"; note "stats-probe, the same 60 calls -> ${h}"
      expect_between "stats-probe also gets the degraded replica's 503s: nothing ejected it" 10 30 "$(field 503 "${h}")"
      expect_eq "stats-probe's Envoy has no outlier_detection counter at all (no ejections_overflow)" \
        "0" "$(probe_cluster_stats stats-probe 'outlier_detection')"
      expect_eq "payments-api's Envoy has ejections_overflow" \
        "1" "$(probe_cluster_stats payments-api 'outlier_detection\.ejections_overflow: ')"
      observe_degraded "${ns}"
    fi
  done

  step "[${ns}] outlierDetection: ${ok#"${REPO_ROOT}"/} (maxEjectionPercent 50)"
  reset_policies "${ns}"
  apply_scenario "${ok}"
  wait_cluster "${ns}" '.outlierDetection.maxEjectionPercent == 50'
  e0="$(cstat "${ns}" outlier_detection.ejections_enforced_total)"
  id="$(run_id)"; h="$(codes "${ns}" 60 "/${id}")"; note "60 calls -> ${h}"
  expect_eq "exactly consecutive5xxErrors (3) calls fail, then the replica is out" "3" "$(field 503 "${h}")"
  expect_eq "ejections_enforced_total +1" "1" "$(( $(cstat "${ns}" outlier_detection.ejections_enforced_total) - e0 ))"
  expect_eq "ejections_active" "1" "$(cstat "${ns}" outlier_detection.ejections_active)"
  ictl proxy-config endpoint "deploy/$(policy_proxy "${ns}")" -n "${ns}" --cluster "$(policy_cluster "${ns}")" | sed 's/^/    /'
  local dip
  dip="$(k -n "${ns}" get pod -l variant=degraded -o jsonpath='{.items[0].status.podIP}')"
  expect_match "the degraded endpoint (${dip}) is marked FAILED by the outlier check" \
    "${dip}:8080 +HEALTHY +FAILED" "$(ictl proxy-config endpoint "deploy/$(policy_proxy "${ns}")" -n "${ns}" --cluster "$(policy_cluster "${ns}")")"

  reset_policies "${ns}"
  k -n "${ns}" scale deploy/fraud-check-degraded --replicas=0 >/dev/null
}

# Run the sidecar scenarios only when executed, not when sourced by step 7.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  step "stats-probe: a second caller with Istio's default stats (observability/stats-probe.yaml)"
  apply_scenario "${REPO_ROOT}/observability/stats-probe.yaml"
  k -n payments rollout status deploy/stats-probe --timeout=180s >/dev/null
  expect_eq "its bootstrap has no inclusion pattern for outlier_detection, upstream_rq_pending or upstream_rq_retry" "0" \
    "$(ictl proxy-config bootstrap deploy/stats-probe -n payments -o json \
      | jq '[.bootstrap.statsConfig.statsMatcher.inclusionList.patterns[] | .safeRegex.regex // empty | select(test("outlier|pending|retry"))] | length')"
  check_connection_pool payments "${REPO_ROOT}/circuit-breaking/connection-pool.yaml"
  check_outlier_detection payments "${REPO_ROOT}/circuit-breaking/outlier-detection.yaml" \
    "${REPO_ROOT}/silent-errors/05-dr-outlier-default-max-ejection.yaml" \
    "${REPO_ROOT}/silent-errors/06-dr-outlier-max-ejection-30.yaml"
  finish
fi
