#!/usr/bin/env bash
# Turns the CoreDNS query log on (or off) in the lab cluster, so
# egress/inventory.sh can name the IPs the sidecars sent to PassthroughCluster.
# Log format: "[INFO] <client ip> <type> <name> <rcode>".
# Lab only: refuses any context that is not a local kind cluster.
# Usage: egress/coredns-query-log.sh on|off [kube context]
set -euo pipefail

mode="${1:?usage: $0 on|off [kube context]}"
ctx="${2:-kind-istio-p2}"
k() { kubectl --context "${ctx}" "$@"; }

# Safety: this script rewrites the CoreDNS ConfigMap and restarts CoreDNS, so
# it refuses to run unless the context points at a local kind API server
# (the same guard as scripts/lib.sh). On a real cluster, do it by hand.
cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${ctx}\")].context.cluster}" 2>/dev/null || true)"
server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
  echo "refusing to run: context ${ctx} is missing or does not point at a local kind API server (server='${server}')" >&2
  exit 3
fi
line='    log . "{remote} {type} {name} {rcode}"'

corefile="$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
if [ "${mode}" = "on" ]; then
  grep -qF "${line}" <<< "${corefile}" && { echo "query log already on"; exit 0; }
  new="$(awk -v l="${line}" '{ print } /^    errors$/ { print l }' <<< "${corefile}")"
else
  grep -qF "${line}" <<< "${corefile}" || { echo "query log already off"; exit 0; }
  new="$(grep -vF "${line}" <<< "${corefile}")"
fi
k -n kube-system get configmap coredns -o json \
  | jq --arg c "${new}" '.data.Corefile = ($c + "\n")' \
  | k apply -f - >/dev/null
# Restart instead of waiting for the reload plugin (30s + jitter per pod).
k -n kube-system rollout restart deploy/coredns >/dev/null
k -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
# rollout status returns while old pods may still be terminating (and still
# answering, with their log about to be lost): wait until only the new ones exist.
want="$(k -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}')"
for _ in $(seq 60); do
  [ "$(k -n kube-system get pod -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "${want}" ] && break
  sleep 2
done
echo "query log ${mode}"
