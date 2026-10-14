#!/usr/bin/env bash
# Tests for ci/resilience-lint.sh. No cluster needed.
# Every working scenario of the lab must pass; every statically detectable
# silent error must fail with its own message. Each case lints the set of
# files that would be applied together (policies with the workloads they
# target, so the lint can count endpoints).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"
LINT="${REPO_ROOT}/ci/resilience-lint.sh"
cd "${REPO_ROOT}" || exit 2

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

SIDECAR="apps/payments-sidecar.yaml"
AMBIENT="apps/payments-ambient.yaml"

# expect_pass <description> <files...>
expect_pass() {
  local desc="$1" out; shift
  if out="$(bash "${LINT}" "$@" 2>&1)"; then
    pass "${desc}"
  else
    fail "${desc}"; printf '%s\n' "${out}" | sed 's/^/        /'
  fi
}
# expect_fail <description> <expected message (fixed string)> <files...>
expect_fail() {
  local desc="$1" msg="$2" out; shift 2
  if out="$(bash "${LINT}" "$@" 2>&1)"; then
    fail "${desc} (lint passed, expected a failure)"
  elif grep -qF -- "${msg}" <<< "${out}"; then
    pass "${desc}"
    grep -F -- "${msg}" <<< "${out}" | head -1 | sed 's/^/        /'
  else
    fail "${desc} (failed without the expected message: ${msg})"; printf '%s\n' "${out}" | sed 's/^/        /'
  fi
}

echo "== working scenarios must pass"
expect_pass "workloads alone (sidecar + ambient)" "${SIDECAR}" "${AMBIENT}"
expect_pass "Istio install (ALLOW_ANY) with both namespaces" istio/install.yaml "${SIDECAR}" "${AMBIENT}"
expect_pass "REGISTRY_ONLY with only the sidecar namespace" istio/install.yaml egress/registry-only.yaml "${SIDECAR}"
for f in timeouts/virtualservice/*.yaml timeouts/gateway-api/*.yaml retries/virtualservice/*.yaml \
         circuit-breaking/*.yaml egress/serviceentry-github.yaml; do
  expect_pass "${f} (with the sidecar workloads)" "${SIDECAR}" "${f}"
done
expect_pass "fault on risk-score + retries on fraud-check (fault one hop below the policy)" \
  "${SIDECAR}" retries/virtualservice/fraud-check-retries.yaml fault-injection/risk-score-abort.yaml
expect_pass "delay on risk-score + retries on fraud-check" \
  "${SIDECAR}" retries/virtualservice/fraud-check-retries.yaml fault-injection/risk-score-delay.yaml
for f in ambient/waypoint.yaml ambient/timeout-httproute.yaml ambient/retries-virtualservice.yaml \
         ambient/connection-pool.yaml ambient/outlier-detection.yaml; do
  expect_pass "${f} (with the ambient workloads)" "${AMBIENT}" "${f}"
done
expect_pass "ambient retries + fault one hop below" "${AMBIENT}" ambient/retries-virtualservice.yaml ambient/fault-risk-score-abort.yaml

echo "== silent errors must fail"
expect_fail "delay injected on the same rule as the timeout" \
  "http rule #0 has a fault and a timeout on the same rule" \
  silent-errors/02-vs-fault-delay-same-route.yaml
expect_fail "abort injected on the same rule as the retries" \
  "http rule #0 has a fault and a timeout on the same rule" \
  silent-errors/03-vs-fault-abort-same-route.yaml
expect_fail "HTTPRoute retry with the standard channel" \
  "rule #0 uses retry, which is experimental in Gateway API v1.6 and not in the standard CRDs" \
  silent-errors/04-httproute-retry-standard-channel.yaml
expect_fail "outlier detection with the default maxEjectionPercent and 2 endpoints" \
  "outlierDetection maxEjectionPercent 10 (default) with 2 endpoint(s) of fraud-check.payments.svc.cluster.local: one ejection is 50%, so no endpoint is ever ejected (needs >= 50)" \
  "${SIDECAR}" silent-errors/05-dr-outlier-default-max-ejection.yaml
expect_fail "outlier detection with the default maxEjectionPercent, endpoints unknown" \
  "outlierDetection without maxEjectionPercent: the default 10% ejects nothing with fewer than 10 endpoints" \
  silent-errors/05-dr-outlier-default-max-ejection.yaml
expect_fail "outlier detection with maxEjectionPercent 30 and 2 endpoints" \
  "outlierDetection maxEjectionPercent 30 with 2 endpoint(s)" \
  "${SIDECAR}" silent-errors/06-dr-outlier-max-ejection-30.yaml
expect_fail "ServiceEntry with resolution NONE" \
  "resolution NONE for api.github.com: the proxy forwards to whatever IP the client dialed" \
  silent-errors/07-serviceentry-resolution-none.yaml
expect_fail "REGISTRY_ONLY with an ambient namespace" \
  "Namespace payments-ambient: outboundTrafficPolicy REGISTRY_ONLY is not enforced for ambient workloads" \
  istio/install.yaml egress/registry-only.yaml "${SIDECAR}" "${AMBIENT}"
expect_fail "VirtualService and HTTPRoute on the same Service (ambient: undefined behavior)" \
  "is also the parent of HTTPRoute payments-ambient/fraud-check" \
  "${AMBIENT}" ambient/retries-virtualservice.yaml ambient/timeout-httproute.yaml

expect_fail "retries without a route timeout (ci/testdata)" \
  "http rule #0 retries without a route timeout: there is no total time budget for the 3 tries" \
  ci/testdata/vs-retries-without-timeout.yaml
expect_fail "perTryTimeout >= timeout (ci/testdata)" \
  "http rule #0 perTryTimeout 1000ms >= timeout 1s: a slow try uses the whole budget and no retry can start" \
  ci/testdata/vs-per-try-timeout-ge-timeout.yaml

echo "== not detectable offline (proved by the lab, scripts/02-timeouts.sh)"
expect_pass "mesh timeout looser than the application timeout passes the lint" \
  "${SIDECAR}" silent-errors/01-vs-timeout-looser-than-app.yaml

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
