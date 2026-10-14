#!/usr/bin/env bash
# Step 5: fault injection as a test of the retry/timeout policy (sidecar mode).
# The policy under test is retries/virtualservice/fraud-check-retries.yaml on
# payments-api -> fraud-check. The faults are injected one hop below, on
# fraud-check -> risk-score (fraud-check:8090 proxies to risk-score). On the
# same hop the test proves nothing: see the silent error at the end and the
# one in step 2. Results are then read back from Prometheus, Jaeger, Kiali and
# Grafana, the same data their dashboards show.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

NS="payments"
SCORE_URL="http://fraud-check:8090"
reset_policies "${NS}"

# score <ns> <path?query> -> "<code> <seconds>" of payments-api -> fraud-check:8090
score() {
  k -n "$1" exec deploy/payments-api -c app -- curl -s -o /dev/null -w '%{http_code} %{time_total}' \
    --max-time 10 "${SCORE_URL}$2" 2>/dev/null || echo "000 0"
}

# score_n <ns> <n> <path?query>: n calls, for the dashboards (Kiali drops
# edges whose rate rounds to zero over its window)
score_n() {
  # shellcheck disable=SC2016 # the loop runs in the pod shell
  k -n "$1" exec deploy/payments-api -c app -- sh -c '
    i=0; while [ "$i" -lt "$1" ]; do curl -s -o /dev/null --max-time 10 "$2"; i=$((i + 1)); done' sh "$2" "${SCORE_URL}$3"
}

step "Policy under test: retries/virtualservice/fraud-check-retries.yaml"
apply_scenario "${REPO_ROOT}/retries/virtualservice/fraud-check-retries.yaml"
wait_route "${NS}" '.[0].route.retryPolicy.numRetries == 2'
wait_json 90 '[.[0].virtualHosts[] | select(.name == "fraud-check.payments.svc.cluster.local:8090") | .routes[0].route.retryPolicy.numRetries] == [2]' \
  ictl proxy-config route deploy/payments-api -n "${NS}" --name 8090 -o json
r="$(score "${NS}" '/f-baseline?status=200')"; note "baseline payments-api -> fraud-check -> risk-score: ${r}"
expect_eq "the two-hop path works" "200" "${r%% *}"
score_n "${NS}" 20 '/f-baseline?status=200'

# reporter="source" vs reporter="destination" for the same calls: the counters
# of payments-api -> fraud-check before the abort. Every failed call of the
# abort phase is one "503 URX" at the source and one 503 per try at fraud-check.
SRC_Q='sum(istio_requests_total{reporter="source", source_workload="payments-api", destination_service_name="fraud-check", response_code="503", response_flags="URX"})'
DST_Q='sum(istio_requests_total{reporter="destination", source_workload="payments-api", destination_workload="fraud-check", response_code="503"})'
SRC0="$(prom_value "${SRC_Q}")"; DST0="$(prom_value "${DST_Q}")"
note "before the abort: source 503 URX = ${SRC0}, destination 503 = ${DST0}"

step "Abort at risk-score: fault-injection/risk-score-abort.yaml"
apply_scenario "${REPO_ROOT}/fault-injection/risk-score-abort.yaml"
wait_json 90 '[.[0].virtualHosts[] | select(.name == "risk-score.payments.svc.cluster.local:8080") | .routes[0].typedPerFilterConfig["envoy.filters.http.fault"] != null] == [true]' \
  ictl proxy-config route deploy/fraud-check -n "${NS}" --name 8080 -o json
ABORT_ID="$(run_id)"
r="$(score "${NS}" "/${ABORT_ID}?status=200")"; note "call -> ${r}"
expect_eq "payments-api gets 503 after its retries" "503" "${r%% *}"
expect_eq "fraud-check's proxy injected the abort 3 times: 1 call + 2 retries from payments-api" "3" \
  "$(proxy_log_count "${NS}" app=fraud-check "${ABORT_ID}" '" 503 FI fault_filter_abort ')"
expect_eq "risk-score was never called" "0" "$(k -n "${NS}" logs deploy/risk-score -c fortio --since=10m | grep -c "/${ABORT_ID}" || true)"
expect_match "payments-api's proxy logs URX (retries exhausted)" '" 503 URX ' "$(access_log "${NS}" payments-api "${ABORT_ID}")"

# Kiali, while the abort is in place: keep a trickle of calls going until the
# edges show up (rate() ignores the first value of a new series).
edges=""
deadline=$((SECONDS + 120))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  score_n "${NS}" 5 "/k$(run_id)?status=200"
  edges="$(svc_get istio-system kiali:20001 '/kiali/api/namespaces/graph?namespaces=payments&graphType=workload&duration=120s' \
    | jq -c '(.elements.nodes | map({key: .data.id, value: (.data.workload // .data.service // "?")}) | from_entries) as $n
      | [.elements.edges[].data | {from: $n[.source], to: $n[.target], err: (.traffic.rates.httpPercentErr // "0")}]')"
  if grep -Eq '"from":"fraud-check","to":"risk-score","err":"[1-9]' <<< "${edges}"; then break; fi
  sleep 5
done
jq -r '.[] | "      Kiali: \(.from) -> \(.to): \(.err)% errors"' <<< "${edges:-[]}"
expect_match "Kiali sees payments-api -> fraud-check failing" '"from":"payments-api","to":"fraud-check","err":"[1-9]' "${edges}"
expect_match "Kiali sees fraud-check -> risk-score failing (the injected abort)" '"from":"fraud-check","to":"risk-score","err":"[1-9]' "${edges}"

step "Delay at risk-score: fault-injection/risk-score-delay.yaml (3s, perTryTimeout is 500ms)"
apply_scenario "${REPO_ROOT}/fault-injection/risk-score-delay.yaml"
wait_json 90 '[.[0].virtualHosts[] | select(.name == "risk-score.payments.svc.cluster.local:8080") | .routes[0].typedPerFilterConfig["envoy.filters.http.fault"].delay != null] == [true]' \
  ictl proxy-config route deploy/fraud-check -n "${NS}" --name 8080 -o json
DELAY_ID="$(run_id)"
r="$(score "${NS}" "/${DELAY_ID}?status=200")"; note "call -> ${r}"
expect_eq "payments-api gets 504" "504" "${r%% *}"
expect_between "after 3 tries of 500ms, inside the 2s budget (ms)" 1450 2050 "$(ms "$(cut -d' ' -f2 <<< "${r}")")"
expect_eq "3 delayed tries at fraud-check's proxy (flag DI)" "3" \
  "$(proxy_log_count "${NS}" app=fraud-check "${DELAY_ID}" '" 0 DI,DC ')"
expect_match "payments-api's proxy logs URX,UT upstream_per_try_timeout" '" 504 URX,UT upstream_per_try_timeout ' "$(access_log "${NS}" payments-api "${DELAY_ID}")"

step "Silent error: abort on the same route as the retries (silent-errors/03-vs-fault-abort-same-route.yaml)"
k -n "${NS}" delete virtualservice risk-score --ignore-not-found >/dev/null
apply_scenario "${REPO_ROOT}/silent-errors/03-vs-fault-abort-same-route.yaml"
wait_route "${NS}" '.[0].typedPerFilterConfig["envoy.filters.http.fault"].abort != null'
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=200")"; note "call -> ${r}"
expect_eq "the caller gets the injected 503" "503" "${r%% *}"
expect_eq "0 requests reached fraud-check: the mesh never retried the injected abort" "0" "$(attempts "${NS}" "${id}")"
expect_match "one FI line in the caller's log, no URX" '" 503 FI fault_filter_abort ' "$(access_log "${NS}" payments-api "${id}")"
id="$(run_id)"
r="$(call "${NS}" "/${id}?status=200" --retry 2 --retry-delay 0.2)"; note "with curl --retry 2 -> ${r}"
expect_eq "client retries do re-send: 3 FI lines in the caller's log" "3" \
  "$(proxy_log_count "${NS}" app=payments-api "${id}" '" 503 FI ')"
reset_policies "${NS}"

step "Prometheus: what the dashboards will show (waiting for two scrapes)"
sleep 35
q='sum by (response_flags) (istio_requests_total{reporter="source", source_workload="fraud-check", destination_service_name="risk-score"})'
note "${q}"
prom "${q}" | jq -r '.data.result[] | "      \(.metric.response_flags) \(.value[1])"'
expect_between "FI (abort injected) requests from fraud-check to risk-score" 3 100000 \
  "$(prom_value 'sum(istio_requests_total{reporter="source", source_workload="fraud-check", destination_service_name="risk-score", response_flags="FI"})')"
expect_between "DI (delay injected) requests from fraud-check to risk-score" 3 100000 \
  "$(prom_value 'sum(istio_requests_total{reporter="source", source_workload="fraud-check", destination_service_name="risk-score", response_flags=~"DI.*"})')"
# Envoy counters restart when a DestinationRule change rebuilds the cluster,
# so read the highest value of the last 30 minutes.
C='outbound|8080||fraud-check.payments.svc.cluster.local'
expect_between "retries are visible: envoy_cluster_upstream_rq_retry (proxyStatsMatcher)" 1 100000 \
  "$(prom_value "max(max_over_time(envoy_cluster_upstream_rq_retry{cluster_name=\"${C}\", pod=~\"payments-api-.*\"}[30m]))")"
expect_between "overflows of step 4 are visible: envoy_cluster_upstream_rq_pending_overflow" 1 100000 \
  "$(prom_value "max(max_over_time(envoy_cluster_upstream_rq_pending_overflow{cluster_name=\"${C}\", pod=~\"payments-api-.*\"}[30m]))")"
expect_between "and as response_flags=\"UO\" in istio_requests_total" 1 100000 \
  "$(prom_value 'sum(istio_requests_total{reporter="source", source_workload="payments-api", destination_service_name="fraud-check", response_flags="UO"})')"
# stats-probe (step 4) has Istio's default stats inclusion list.
expect_eq "without proxyStatsMatcher (stats-probe): no envoy_cluster_upstream_rq_pending_overflow series for fraud-check" "0" \
  "$(prom_value "count(envoy_cluster_upstream_rq_pending_overflow{cluster_name=\"${C}\", pod=~\"stats-probe-.*\"}) or vector(0)")"
expect_eq "nor envoy_cluster_outlier_detection_ejections_overflow" "0" \
  "$(prom_value "count(envoy_cluster_outlier_detection_ejections_overflow{cluster_name=\"${C}\", pod=~\"stats-probe-.*\"}) or vector(0)")"
expect_between "its overflows are still in istio_requests_total as response_flags=\"UO\"" 1 100000 \
  "$(prom_value 'sum(istio_requests_total{reporter="source", source_workload="stats-probe", destination_service_name="fraud-check", response_flags="UO"})')"

SRC1="$(prom_value "${SRC_Q}")"; DST1="$(prom_value "${DST_Q}")"
src=$((SRC1 - SRC0)); dst=$((DST1 - DST0))
note "abort phase, payments-api -> fraud-check: reporter=\"source\" +${src} calls (503 URX), reporter=\"destination\" +${dst} tries (503)"
expect_between "reporter=\"source\" counted the aborted calls" 5 100000 "${src}"
tol=$(( src * 3 / 20 > 2 ? src * 3 / 20 : 2 ))
expect_between "reporter=\"destination\" counted every try: 3 per call (1 + 2 retries), within 5%" \
  "$(( src * 3 - tol ))" "$(( src * 3 + tol ))" "${dst}"

step "Jaeger: the trace of the aborted call shows each retry as its own span"
EMPTY='{"spans":[]}'
trace=""
deadline=$((SECONDS + 60))
while [ -z "${trace}" ] && [ "${SECONDS}" -lt "${deadline}" ]; do
  trace="$(svc_get istio-system tracing:80 '/jaeger/api/traces?service=payments-api.payments&limit=200&lookback=1h' \
    | jq -c --arg id "${ABORT_ID}" '[.data[] | select(any(.spans[].tags[]; .key == "http.url" and (.value | contains($id))))][0] // empty')"
  [ -n "${trace}" ] || sleep 5
done
[ -n "${trace}" ] || trace="${EMPTY}"
jq -r '.spans | sort_by(.startTime)[] | "      \(.operationName) " + ([.tags[] | select(.key == "span.kind" or .key == "http.status_code" or .key == "response_flags") | "\(.key)=\(.value)"] | join(" "))' <<< "${trace}"
expect_eq "1 client span from payments-api" "1" \
  "$(jq '[.spans[] | select(.operationName | startswith("fraud-check")) | select(any(.tags[]; .key == "span.kind" and .value == "client"))] | length' <<< "${trace}")"
expect_eq "3 server spans at fraud-check (one per try)" "3" \
  "$(jq '[.spans[] | select(.operationName | startswith("fraud-check")) | select(any(.tags[]; .key == "span.kind" and .value == "server"))] | length' <<< "${trace}")"
expect_eq "3 risk-score client spans with response_flags=FI" "3" \
  "$(jq '[.spans[] | select(any(.tags[]; .key == "response_flags" and .value == "FI"))] | length' <<< "${trace}")"

step "Grafana: the Istio dashboards that ship with the addon"
dash="$(svc_get istio-system grafana:3000 '/api/search?query=Istio' | jq -r '[.[].title] | join(", ")')"
note "${dash}"
expect_match "Istio Service and Workload dashboards are provisioned" 'Istio Service Dashboard.*Istio Workload Dashboard' "${dash}"

step "Alerts (observability/alerts.yaml): NR, NC and UO provoked on purpose"
# Two broken routes (observability/alert-drill-routes.yaml) and the connection
# pool of step 4, fed with a trickle of calls until Prometheus reports the
# alerts as pending (condition true, waiting for "for") or firing. Rules are
# evaluated every minute and rate() needs two scrapes of each series.
reset_policies "${NS}"
apply_scenario "${REPO_ROOT}/observability/alert-drill-routes.yaml"
apply_scenario "${REPO_ROOT}/circuit-breaking/connection-pool.yaml"
wait_route "${NS}" 'length == 2'
wait_cluster "${NS}" '.circuitBreakers.thresholds[0].maxConnections == 2'
expect_eq "a path without a route answers 404 (NR)" "404=3" "$(codes "${NS}" 3 /drill-unrouted)"
expect_eq "a route to the undefined subset v2 answers 503 (NC)" "503=3" "$(codes "${NS}" 3 /v2/drill)"
started=${SECONDS}
nr=inactive; nc=inactive; uo=inactive
deadline=$((SECONDS + 300))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  codes "${NS}" 3 /drill-unrouted >/dev/null
  codes "${NS}" 3 /v2/drill >/dev/null
  k -n "${NS}" exec deploy/payments-api -c load -- fortio load -c 6 -qps 0 -n 30 -loglevel Error \
    "${FRAUD_URL}/api/drill?delay=200ms" >/dev/null 2>&1 || true
  nr="$(alert_state IstioRouteNotFound "${NS}" payments-api)"
  nc="$(alert_state IstioClusterNotFound "${NS}" payments-api)"
  uo="$(alert_state IstioUpstreamOverflow "${NS}" payments-api)"
  [[ "${nr}${nc}${uo}" =~ inactive ]] || break
  sleep 10
done
note "after $((SECONDS - started))s: IstioRouteNotFound=${nr} IstioClusterNotFound=${nc} IstioUpstreamOverflow=${uo}"
show_alerts "${NS}" payments-api
expect_match "IstioRouteNotFound is pending or firing for payments-api" '^(pending|firing)$' "${nr}"
expect_match "IstioClusterNotFound is pending or firing for payments-api" '^(pending|firing)$' "${nc}"
expect_match "IstioUpstreamOverflow is pending or firing for payments-api" '^(pending|firing)$' "${uo}"
reset_policies "${NS}"

finish
