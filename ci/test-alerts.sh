#!/usr/bin/env bash
# Offline tests of observability/alerts.yaml (no cluster):
#   1. promtool check rules: syntax and PromQL;
#   2. promtool test rules: the unit tests in observability/alerts_test.yaml;
#   3. mutants: copies of the rules with one deliberate mistake each, which the
#      unit tests must reject (proves the tests can fail).
# Uses the promtool pinned by tools/install-cli.sh (same version as the
# Prometheus of the Istio 1.31.1 addons).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null
PROMTOOL="${REPO_ROOT}/bin/promtool"
RULES="${REPO_ROOT}/observability/alerts.yaml"
TESTS="${REPO_ROOT}/observability/alerts_test.yaml"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

echo "==> promtool $("${PROMTOOL}" --version 2>&1 | sed -n '1s/^promtool, version \([^ ]*\).*/\1/p')"
if out="$("${PROMTOOL}" check rules "${RULES}" 2>&1)"; then
  pass "promtool check rules: $(grep -o '[0-9]* rules found' <<< "${out}")"
else
  fail "promtool check rules"; echo "${out}"
fi
if out="$("${PROMTOOL}" test rules "${TESTS}" 2>&1)"; then
  pass "promtool test rules: $(grep -c '^- name:' "${TESTS}") test groups"
else
  fail "promtool test rules"; echo "${out}"
fi

# mutant <description> <sed expression>: the tests must fail on the mutated rules.
mutant() {
  local tmp
  tmp="$(mktemp -d)"
  sed -E "$2" "${RULES}" > "${tmp}/alerts.yaml"
  cp "${TESTS}" "${tmp}/alerts_test.yaml"
  if cmp -s "${RULES}" "${tmp}/alerts.yaml"; then
    fail "mutant '$1': the sed expression changed nothing"
  elif "${PROMTOOL}" test rules "${tmp}/alerts_test.yaml" >/dev/null 2>&1; then
    fail "mutant '$1' was not caught by the tests"
  else
    pass "mutant '$1' is caught by the tests"
  fi
  rm -rf "${tmp}"
}
echo "==> mutants"
mutant "DC counted at any reporter" \
  '/DC\(,\.\*\)\?/ s/reporter=~"source\|waypoint", //'
mutant "ratio threshold 1% instead of 5%" 's/> 0\.05$/> 0.01/'
mutant "UT matched as an exact value" 's/"\(\.\*,\)\?UT\(,\.\*\)\?"/"UT"/'
mutant "waypoint reporter left out" 's/reporter=~"source\|waypoint"/reporter="source"/g'
mutant "BlackHoleCluster not excluded from UH" 's/, destination_service_name!="BlackHoleCluster"//'
mutant "NR at the ingress gateway not excluded" 's/, source_workload!~"istio-ingressgateway\.\*|\.+-istio"//'
mutant "NR without for (fires on one request)" '/alert: IstioRouteNotFound/,/for:/ s/for: 5m/for: 0m/'

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
