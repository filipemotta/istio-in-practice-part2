#!/usr/bin/env bash
# Outbound inventory of a sidecar namespace before switching to REGISTRY_ONLY.
# Read-only. For every pod of the namespace it lists:
#   - the destinations its sidecar sent to PassthroughCluster (traffic to
#     hosts outside the mesh registry), from the Envoy access log. For TLS
#     traffic that is an IP:port only; the sidecar does not record the SNI;
#   - the external names the pod resolved, from the CoreDNS query log (needs
#     the CoreDNS "log" plugin; step 6 of the lab turns it on), which is what
#     turns those IPs into hostnames for your ServiceEntries.
# Read-only (get pods, read logs), so it has no lab-only guard and can be
# pointed at any cluster: it always passes --context, defaulting to the lab's
# kind-istio-p2, never to your current kubectl context.
# Usage: egress/inventory.sh <namespace> [kube context]
set -euo pipefail

ns="${1:?usage: $0 <namespace> [kube context]}"
ctx="${2:-kind-istio-p2}"
k() { kubectl --context "${ctx}" "$@"; }

dns="$(k -n kube-system logs -l k8s-app=kube-dns --tail=-1 2>/dev/null || true)"
k -n "${ns}" get pod -o json \
  | jq -r '.items[] | select(any(.spec.initContainers[]?, .spec.containers[]; .name == "istio-proxy"))
           | "\(.metadata.name) \(.status.podIP)"' \
  | while read -r pod ip; do
      echo "pod ${pod} (${ip})"
      k -n "${ns}" logs "${pod}" -c istio-proxy 2>/dev/null \
        | awk '/ PassthroughCluster / { for (i = 1; i <= NF; i++) if ($i == "PassthroughCluster") print $(i + 2) }' \
        | sort | uniq -c | sort -rn | awk '{ printf "  passthrough %-24s connections=%s\n", $2, $1 }'
      # CoreDNS log format set by the lab: "[INFO] <client ip> <type> <name> <rcode>"
      awk -v ip="${ip}" '$1 == "[INFO]" && $2 == ip { print $4 }' <<< "${dns}" \
        | { grep -v '\.cluster\.local\.$' || true; } | sed 's/\.$//' | sort | uniq -c | sort -rn \
        | awk '{ printf "  resolved    %-24s queries=%s\n", $2, $1 }'
    done
