#!/usr/bin/env bash
# Offline test of the lab's context guard (no cluster, no API call): every lab
# step and egress/coredns-query-log.sh must refuse to run unless the context
# kind-istio-p2 points at a local kind API server. Each case uses a throwaway
# KUBECONFIG; the "remote" servers are in 203.0.113.0/24 (TEST-NET-3,
# documentation only), so even a broken guard could not reach a real cluster.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null
export PATH="${REPO_ROOT}/bin:${PATH}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# kubeconfig <file> <context cluster> <server of that cluster> [<decoy cluster> <decoy server>]
kubeconfig() {
  {
    echo "apiVersion: v1"
    echo "kind: Config"
    echo "clusters:"
    echo "- name: $2"
    echo "  cluster: {server: \"$3\"}"
    [ -z "${4:-}" ] || { echo "- name: $4"; echo "  cluster: {server: \"$5\"}"; }
    echo "contexts:"
    echo "- name: kind-istio-p2"
    echo "  context: {cluster: $2, user: u}"
    echo "users:"
    echo "- name: u"
    echo "  user: {}"
    echo "current-context: kind-istio-p2"
  } > "$1"
}
kubeconfig "${TMP}/remote" kind-istio-p2 "https://203.0.113.10:443"
# The context named kind-istio-p2 uses a remote cluster, while a local-looking
# cluster entry carries the lab's name: the guard must follow the context.
kubeconfig "${TMP}/decoy" prod "https://203.0.113.20:443" kind-istio-p2 "https://127.0.0.1:6443"
printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' > "${TMP}/missing"

# expect_refusal <description> <kubeconfig> <command...>
expect_refusal() {
  local desc="$1" kc="$2" out rc; shift 2
  out="$(KUBECONFIG="${kc}" "$@" 2>&1)"; rc=$?
  if [ "${rc}" -eq 3 ] && grep -q '^refusing to run' <<< "${out}"; then
    pass "${desc}"
  else
    fail "${desc} (exit ${rc}: $(tail -1 <<< "${out}"))"
  fi
}

for case in remote decoy missing; do
  echo "==> kubeconfig: ${case}"
  for s in 02-timeouts 03-retries 04-circuit-breaking 05-fault-injection 06-egress 07-ambient; do
    expect_refusal "scripts/${s}.sh refuses (${case})" "${TMP}/${case}" bash "${REPO_ROOT}/scripts/${s}.sh"
  done
  expect_refusal "egress/coredns-query-log.sh refuses (${case})" "${TMP}/${case}" \
    bash "${REPO_ROOT}/egress/coredns-query-log.sh" on kind-istio-p2
done

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
