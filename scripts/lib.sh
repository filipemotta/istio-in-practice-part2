#!/usr/bin/env bash
# Shared helpers sourced by the lab scripts. Not meant to be run directly.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export PATH="${REPO_ROOT}/bin:${PATH}"

CLUSTER_NAME="istio-p2"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
ISTIO_VERSION="1.31.1"
GATEWAY_API_VERSION="v1.6.0"
OUT="${REPO_ROOT}/out"
mkdir -p "${OUT}"
export CLUSTER_NAME KUBE_CONTEXT ISTIO_VERSION GATEWAY_API_VERSION OUT

# Safety: the lab only ever talks to its own kind cluster. Every kubectl and
# istioctl call passes --context explicitly, so the current context of your
# kubeconfig is never used; on top of that, refuse to run if the lab context
# does not point at a kind cluster with the expected name.
assert_lab_context() {
  local cluster server
  # Resolve context -> cluster -> server: the cluster the context really uses.
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "refusing to run: context ${KUBE_CONTEXT} is missing or does not point at a local kind API server (server='${server}')" >&2
    exit 3
  fi
}

k()    { kubectl --context "${KUBE_CONTEXT}" "$@"; }
ictl() { istioctl --context "${KUBE_CONTEXT}" "$@"; }

ensure_clis() { bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null; }

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- assertions: failures are counted, the script exits non-zero at the end ---
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}
# expect_match <description> <extended regex> <actual>
expect_match() {
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for /$2/ in: $3)"; fi
}
# expect_no_match <description> <extended regex> <actual>
expect_no_match() {
  if grep -Eq -- "$2" <<< "$3"; then fail "$1 (unexpected /$2/ in: $3)"; else pass "$1"; fi
}
# expect_between <description> <min> <max> <actual integer>
expect_between() {
  if [[ "$4" =~ ^-?[0-9]+$ ]] && [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then
    pass "$1 (got $4, accepted range $2..$3)"
  else
    fail "$1 (got $4, accepted range $2..$3)"
  fi
}

finish() {
  printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
  [ "${FAILED}" -eq 0 ]
}

# --- the call under test: payments-api -> fraud-check ---
# payments-api is a curl container standing in for the service code: curl's
# --max-time is the application timeout, curl's --retry is the client library
# retry. Every request leaves from that pod, so the mesh policy applied is the
# one of its sidecar (namespace payments) or of the waypoint (payments-ambient).
FRAUD_URL="http://fraud-check:8080"

# run_id -> a unique token, used in the request path so that the attempts of
# one test can be counted in the fraud-check logs.
run_id() { printf 'r%s%04d' "$(date +%s)" "$((RANDOM % 10000))"; }

# call <ns> <path?query> [extra curl args...] -> "<http code> <seconds> <curl exit>"
# One request from payments-api, timed by curl itself.
call() {
  local ns="$1" path="$2"; shift 2
  # shellcheck disable=SC2016 # the command runs in the pod shell
  k -n "${ns}" exec deploy/payments-api -c app -- sh -c '
    url="$1"; shift
    out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" "$@" "${url}")"; rc=$?
    echo "${out:-000 0} ${rc}"' sh "${FRAUD_URL}${path}" "$@" 2>/dev/null || echo "000 0 99"
}
# codes <ns> <requests> <path?query> [extra curl args...] -> histogram, e.g. "200=95 503=5"
codes() {
  local ns="$1" n="$2" path="$3"; shift 3
  # shellcheck disable=SC2016 # the loop runs in the pod shell
  k -n "${ns}" exec deploy/payments-api -c app -- sh -c '
    n="$1"; url="$2"; shift 2; i=0
    while [ "$i" -lt "$n" ]; do
      curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "$@" "${url}"
      i=$((i + 1))
    done' sh "${n}" "${FRAUD_URL}${path}" "$@" | sort | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }'
}
# field <name> <"200=.. 503=.."> -> the number for that name (0 if absent)
field() {
  local v
  v="$(tr ' ' '\n' <<< "$2" | sed -n "s/^$1=//p")"
  printf '%s' "${v:-0}"
}
# ms <seconds as printed by curl, e.g. 1.002345> -> integer milliseconds
ms() { awk -v s="$1" 'BEGIN { printf "%d", s * 1000 }'; }

# attempts <ns> <run id> -> how many requests carrying that token reached a
# fraud-check pod (fortio -loglevel Verbose logs one JSON line per request).
# Counts across every fraud-check pod; waits a little for slow responses.
attempts() {
  local ns="$1" id="$2" total=0 n p
  sleep "${3:-1}"
  for p in $(k -n "${ns}" get pod -l app=fraud-check -o jsonpath='{.items[*].metadata.name}'); do
    n="$(k -n "${ns}" logs "${p}" -c fortio --since=10m 2>/dev/null | grep -c "\"url\":\"/${id}" || true)"
    total=$((total + n))
  done
  printf '%s' "${total}"
}
# served <ns> <run id> <status> -> requests carrying that token that a
# fraud-check pod answered with that status (as fortio logged it)
served() {
  local ns="$1" id="$2" status="$3" total=0 n p
  for p in $(k -n "${ns}" get pod -l app=fraud-check -o jsonpath='{.items[*].metadata.name}'); do
    n="$(k -n "${ns}" logs "${p}" -c fortio --since=10m 2>/dev/null | grep "\"url\":\"/${id}" | grep -c "\"status\":${status}," || true)"
    total=$((total + n))
  done
  printf '%s' "${total}"
}

# --- the proxy that applies the policy of payments-api -> fraud-check ---
# Sidecar mode: payments-api's own istio-proxy, cluster "outbound|...".
# Ambient mode: the namespace waypoint, cluster "inbound-vip|...".
policy_proxy() {
  if [ "$1" = "payments-ambient" ]; then printf 'waypoint'; else printf 'payments-api'; fi
}
# policy_cluster <ns> [port] -> the Envoy cluster name of fraud-check on that proxy
policy_cluster() {
  if [ "$1" = "payments-ambient" ]; then
    printf 'inbound-vip|%s|http|fraud-check.%s.svc.cluster.local' "${2:-8080}" "$1"
  else
    printf 'outbound|%s||fraud-check.%s.svc.cluster.local' "${2:-8080}" "$1"
  fi
}
# proxy_stat <ns> <deployment> <fixed substring> -> "name: value" Envoy stats of its proxy
proxy_stat() {
  k -n "$1" exec "deploy/$2" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null | grep -F -- "$3" || true
}
# stat_value <"name: value" lines> <exact stat name> -> value (0 if absent)
stat_value() {
  local v
  v="$(awk -v n="$2" -F': ' '$1 == n { print $2 }' <<< "$1" | head -1)"
  printf '%s' "${v:-0}"
}
# cstat <ns> <stat suffix> -> value of that fraud-check cluster stat on the policy proxy
cstat() {
  local c
  # Istio tags the cluster name in stat names: "cluster.<name>;.<stat>"
  c="cluster.$(policy_cluster "$1");.$2"
  stat_value "$(proxy_stat "$1" "$(policy_proxy "$1")" "${c}")" "${c}"
}

# reset_policies <ns>: remove every routing and traffic policy of the
# namespace, so each scenario starts from "no policy at all".
reset_policies() {
  k -n "$1" delete httproute,virtualservice,destinationrule,serviceentry --all --ignore-not-found >/dev/null
}

# apply_scenario <file>: apply and print the file path, for the log.
apply_scenario() {
  note "kubectl apply -f ${1#"${REPO_ROOT}"/}"
  k apply -f "$1" >/dev/null
}

# policy_route <ns> [port] -> the Envoy routes the policy proxy uses for
# fraud-check, as compact JSON (what istiod actually pushed).
policy_route() {
  local port="${2:-8080}"
  if [ "$1" = "payments-ambient" ]; then
    ictl proxy-config route deploy/waypoint -n "$1" -o json 2>/dev/null \
      | jq -c --arg n "$(policy_cluster "$1" "${port}")" '[.[] | select(.name == $n) | .virtualHosts[].routes[]]'
  else
    ictl proxy-config route deploy/payments-api -n "$1" --name "${port}" -o json 2>/dev/null \
      | jq -c --arg vh "fraud-check.$1.svc.cluster.local:${port}" '[.[0].virtualHosts[] | select(.name == $vh) | .routes[]]'
  fi
}
# policy_cluster_config <ns> -> the Envoy cluster config of fraud-check on the policy proxy
policy_cluster_config() {
  ictl proxy-config cluster "deploy/$(policy_proxy "$1")" -n "$1" -o json 2>/dev/null \
    | jq -c --arg n "$(policy_cluster "$1")" '[.[] | select(.name == $n)][0]'
}
# wait_route <ns> <jq filter on the routes array>: wait (90s) for the push.
wait_route() { wait_json 90 "$2" policy_route "$1"; }
# wait_cluster <ns> <jq filter on the cluster>: wait (90s) for the push.
wait_cluster() { wait_json 90 "$2" policy_cluster_config "$1"; }

# proxy_log_count <ns> <pod selector> <run id> [extended regex]: access log
# lines of the istio-proxy of those pods (or of the waypoint) that carry the
# run id and match the regex.
proxy_log_count() {
  local ns="$1" sel="$2" id="$3" re="${4:-.}" total=0 n p
  sleep 2
  for p in $(k -n "${ns}" get pod -l "${sel}" -o jsonpath='{.items[*].metadata.name}'); do
    n="$(k -n "${ns}" logs "${p}" -c istio-proxy --since=10m 2>/dev/null | grep -F "/${id}" | grep -Ec -- "${re}" || true)"
    total=$((total + n))
  done
  printf '%s' "${total}"
}
# access_log <ns> <deployment> <run id> -> the last istio-proxy access log line with it
access_log() {
  sleep 2
  k -n "$1" logs "deploy/$2" -c istio-proxy --since=10m 2>/dev/null | grep -F "$3" | tail -1
}

# wait_json <seconds> <jq filter that must output true> <command...>:
# re-runs the command every 2s until the filter holds.
wait_json() {
  local deadline=$((SECONDS + $1)) filter="$2"; shift 2
  until [ "$("$@" 2>/dev/null | jq -r "${filter}" 2>/dev/null)" = "true" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout waiting for: ${filter}"; return 1; }
    sleep 2
  done
}
# wait_for <seconds> <expected> <command...>: re-runs the command every 2s until
# its output equals <expected>. Returns 1 on timeout (callers then assert).
wait_for() {
  local deadline=$((SECONDS + $1)) expected="$2"; shift 2
  until [ "$("$@" 2>/dev/null)" = "${expected}" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || return 1
    sleep 2
  done
}

# --- observability backends, read through the API server service proxy ---
# (no port-forward needed; the same data the dashboards show)
svc_get() { # <namespace> <service:port> <path?query>
  k get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"
}
# prom <PromQL> -> the raw JSON answer of the Prometheus instant query API
prom() {
  local q
  q="$(jq -rn --arg q "$1" '$q | @uri')"
  svc_get istio-system prometheus:9090 "/api/v1/query?query=${q}"
}
# prom_value <PromQL> -> the first sample value rounded to an integer ("0" if empty)
prom_value() {
  prom "$1" | jq -r '[.data.result[0].value[1] // "0" | tonumber] | .[0] | round'
}

# --- alert rules (observability/alerts.yaml) in the addon Prometheus ---
# The samples/addons Prometheus reads /etc/config/alerting_rules.yml from its
# "prometheus" ConfigMap; its config-reloader sidecar reloads Prometheus when
# the kubelet updates the mounted file (up to a minute or two).
ALERT_GROUP="istio-response-flags"
load_alert_rules() {
  local patch
  patch="$(jq -n --rawfile r "${REPO_ROOT}/observability/alerts.yaml" '{data: {"alerting_rules.yml": $r}}')"
  k -n istio-system patch configmap prometheus --type merge -p "${patch}" >/dev/null
}
# alert_rule_names -> the alert names of observability/alerts.yaml, comma-separated
alert_rule_names() { sed -n 's/^  - alert: //p' "${REPO_ROOT}/observability/alerts.yaml" | paste -sd, -; }
# loaded_alert_rules -> the alert names Prometheus has loaded for the group, comma-separated
loaded_alert_rules() {
  svc_get istio-system prometheus:9090 '/api/v1/rules?type=alert' \
    | jq -r --arg g "${ALERT_GROUP}" '[.data.groups[] | select(.name == $g) | .rules[].name] | join(",")'
}
# alert_state <alertname> <source_workload_namespace> <source_workload> ->
# "firing", "pending" or "inactive" (Prometheus /api/v1/alerts)
alert_state() {
  svc_get istio-system prometheus:9090 '/api/v1/alerts' \
    | jq -r --arg a "$1" --arg ns "$2" --arg w "$3" '[.data.alerts[]
        | select(.labels.alertname == $a and .labels.source_workload_namespace == $ns and .labels.source_workload == $w)
        | .state] | if any(.[]; . == "firing") then "firing" elif length > 0 then .[0] else "inactive" end'
}
# show_alerts <ns> <workload> -> one line per active alert of that caller
show_alerts() {
  svc_get istio-system prometheus:9090 '/api/v1/alerts' \
    | jq -r --arg ns "$1" --arg w "$2" '.data.alerts[]
        | select(.labels.source_workload_namespace == $ns and .labels.source_workload == $w)
        | "      \(.labels.alertname) \(.state) destination_service=\(.labels.destination_service // "-") value=\(.value) since=\(.activeAt)"'
}
