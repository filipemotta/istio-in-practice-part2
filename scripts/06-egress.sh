#!/usr/bin/env bash
# Step 6: traffic that leaves the mesh. ALLOW_ANY (the default) lets anything
# out; inventory it; switch to REGISTRY_ONLY and watch it break; register the
# one host that should work with a ServiceEntry (resolution: DNS); show why
# resolution: NONE is a hole. Also: what REGISTRY_ONLY does NOT do in ambient.
# Needs Internet egress from the kind nodes. Restores ALLOW_ANY at the end.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

NS="payments"
ALLOWED="api.github.com"     # the integration payments-api is supposed to use
FORGOTTEN="www.google.com"   # traffic nobody declared

# ext <ns> <host> [extra curl args...] -> "<http code> <curl exit>" for https://<host>/
ext() {
  local ns="$1" host="$2"; shift 2
  # shellcheck disable=SC2016 # runs in the pod shell
  k -n "${ns}" exec deploy/payments-api -c app -- sh -c '
    h="$1"; shift
    c="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@" "https://${h}/")"; rc=$?
    echo "${c:-000} ${rc}"' sh "${host}" "$@" 2>/dev/null || echo "000 99"
}
# mesh_mode -> the outbound traffic policy in the mesh config
mesh_mode() { k -n istio-system get cm istio -o jsonpath='{.data.mesh}' | yq '.outboundTrafficPolicy.mode'; }
# wait_ext <seconds> <ns> <host> <expected "code exit"> : wait for the push
wait_ext() {
  local deadline=$((SECONDS + $1))
  until [ "$(ext "$2" "$3")" = "$4" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || return 1
    sleep 3
  done
}
# upstream_of <access log line> -> the upstream host field ("ip:port")
upstream_of() { awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^outbound\|443\|\|/) print $(i - 1) }' <<< "$1" | tr -d '"'; }
# mark: remember "now"; sidecar_log only reads log lines written after it.
SINCE=""
mark() { SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# sidecar_log <fixed string> [lines] [second fixed string] -> the last matching access log lines of
# payments-api's sidecar since the last mark. TCP connections are logged
# when they close, so it waits (30s) until the wanted number of lines is there.
sidecar_log() {
  local deadline=$((SECONDS + 30)) want="${2:-1}" out=""
  while :; do
    out="$(k -n "${NS}" logs deploy/payments-api -c istio-proxy --since-time="${SINCE}" 2>/dev/null | grep -F -- "$1" | grep -F -- "${3:-$1}" | tail -"${want}" || true)"
    [ "$(grep -c . <<< "${out}" || true)" -lt "${want}" ] || break
    [ "${SECONDS}" -lt "${deadline}" ] || break
    sleep 2
  done
  printf '%s' "${out}"
}
# pod_ip_of <host> -> one IPv4 address of that host, resolved from payments-api
pod_ip_of() {
  k -n "${NS}" exec deploy/payments-api -c app -- nslookup "$1" 2>/dev/null | awk '/^Address: [0-9.]+$/ { print $2; exit }'
}

reset_policies "${NS}"
if [ "$(mesh_mode)" != "ALLOW_ANY" ]; then
  note "a previous run stopped half-way: restoring istio/install.yaml (ALLOW_ANY) first"
  ictl install -y -f "${REPO_ROOT}/istio/install.yaml" >/dev/null 2>&1
fi

step "Default: outboundTrafficPolicy ${ALLOWED} and ${FORGOTTEN} both reachable"
expect_eq "mesh config" "ALLOW_ANY" "$(mesh_mode)"
bash "${REPO_ROOT}/egress/coredns-query-log.sh" on "${KUBE_CONTEXT}" | sed 's/^/    /'
mark
for h in "${ALLOWED}" "${FORGOTTEN}"; do
  r="$(ext "${NS}" "${h}")"; note "https://${h}/ -> ${r}"
  expect_eq "ALLOW_ANY: ${h} answers" "0" "${r##* }"
done

step "Inventory before closing the door"
log="$(sidecar_log ' PassthroughCluster ' 2)"
printf '%s\n' "${log}" | cut -c1-200 | sed 's/^/    /'
expect_eq "the sidecar logs both connections as PassthroughCluster" "2" "$(grep -c ' PassthroughCluster ' <<< "${log}")"
expect_eq "with the destination IP but no hostname (requested server name '-')" "2" \
  "$(grep -cE ' PassthroughCluster [0-9.:]+ [0-9.:]+ [0-9.:]+ - ' <<< "${log}")"
sleep 35
q='sum by (source_workload, destination_service_name) (istio_tcp_connections_opened_total{reporter="source", destination_service_name="PassthroughCluster"})'
note "Prometheus: ${q}"
prom "${q}" | jq -r '.data.result[] | "      \(.metric.source_workload) -> \(.metric.destination_service_name): \(.value[1])"'
expect_between "Prometheus counts payments-api's connections to PassthroughCluster" 2 100000 \
  "$(prom_value 'sum(istio_tcp_connections_opened_total{reporter="source", destination_service_name="PassthroughCluster", source_workload="payments-api", source_workload_namespace="payments"})')"
inv="$(bash "${REPO_ROOT}/egress/inventory.sh" "${NS}" "${KUBE_CONTEXT}")"
printf '%s\n' "${inv}" | sed 's/^/    /'
expect_match "the DNS log names what the IPs were: ${ALLOWED}" "resolved +${ALLOWED} " "${inv}"
expect_match "and ${FORGOTTEN}" "resolved +${FORGOTTEN} " "${inv}"

step "REGISTRY_ONLY: istioctl install -f istio/install.yaml -f egress/registry-only.yaml"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml" -f "${REPO_ROOT}/egress/registry-only.yaml" 2>&1 | tail -1 | sed 's/^/    /'
expect_eq "mesh config" "REGISTRY_ONLY" "$(mesh_mode)"
wait_ext 90 "${NS}" "${FORGOTTEN}" "000 35" || true
mark
for h in "${ALLOWED}" "${FORGOTTEN}"; do
  r="$(ext "${NS}" "${h}")"; note "https://${h}/ -> ${r}"
  expect_eq "sidecar: ${h} blocked (curl exit 35, TLS handshake reset)" "000 35" "${r}"
done
log="$(sidecar_log ' BlackHoleCluster ')"
note "access log: ${log:0:170}"
expect_match "logged as BlackHoleCluster with response flag UH" '" 0 UH .* BlackHoleCluster ' "${log}"
r="$(call "${NS}" '/e-mesh?status=200')"
expect_eq "in-mesh traffic is unaffected: fraud-check 200" "200" "${r%% *}"

step "Alert: IstioEgressBlocked (observability/alerts.yaml) while REGISTRY_ONLY drops ${FORGOTTEN}"
# HTTPS to a denied host is a TCP connection to BlackHoleCluster with flag UH:
# istio_tcp_connections_opened_total, not istio_requests_total. Keep a trickle
# of blocked calls until Prometheus reports the alert pending or firing.
started=${SECONDS}; st=inactive; deadline=$((SECONDS + 300))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  ext "${NS}" "${FORGOTTEN}" >/dev/null
  st="$(alert_state IstioEgressBlocked "${NS}" payments-api)"
  [ "${st}" = "inactive" ] || break
  sleep 10
done
note "after $((SECONDS - started))s: IstioEgressBlocked=${st}"
show_alerts "${NS}" payments-api | grep IstioEgressBlocked || true
expect_eq "Prometheus has payments-api's BlackHoleCluster connections with flag UH" "UH" \
  "$(prom 'sum by (response_flags) (istio_tcp_connections_opened_total{reporter="source", source_workload="payments-api", destination_service_name="BlackHoleCluster"})' | jq -r '[.data.result[].metric.response_flags] | join(",")')"
expect_match "IstioEgressBlocked is pending or firing for payments-api" '^(pending|firing)$' "${st}"

step "Silent error: REGISTRY_ONLY does not apply to ambient workloads (ztunnel)"
for h in "${ALLOWED}" "${FORGOTTEN}"; do
  r="$(ext payments-ambient "${h}")"; note "payments-ambient https://${h}/ -> ${r}"
  expect_eq "ambient pod still reaches ${h}" "0" "${r##* }"
done

step "ServiceEntry for the integration that should work: egress/serviceentry-github.yaml (resolution: DNS)"
apply_scenario "${REPO_ROOT}/egress/serviceentry-github.yaml"
wait_ext 90 "${NS}" "${ALLOWED}" "200 0" || true
mark
r="$(ext "${NS}" "${ALLOWED}")"; note "https://${ALLOWED}/ -> ${r}"
expect_eq "${ALLOWED} works again" "200 0" "${r}"
r="$(ext "${NS}" "${FORGOTTEN}")"; note "https://${FORGOTTEN}/ -> ${r}"
expect_eq "${FORGOTTEN} is still blocked" "000 35" "${r}"
log="$(sidecar_log "outbound|443||${ALLOWED}")"
note "access log: ${log:0:200}"
expect_match "now logged with its own cluster and SNI" "outbound\\|443\\|\\|${ALLOWED} .* ${ALLOWED} " "${log}"

step "resolution: DNS ignores the IP the application dialed"
mark
gip="$(pod_ip_of "${FORGOTTEN}")"; note "${FORGOTTEN} resolves to ${gip}; dial it while claiming to be ${ALLOWED}"
hdr="$(k -n "${NS}" exec deploy/payments-api -c app -- curl -sk -o /dev/null -D - --max-time 8 \
  --resolve "${ALLOWED}:443:${gip}" "https://${ALLOWED}/" | tr -d '\r' | grep -i '^server:' || true)"
log="$(sidecar_log "outbound|443||${ALLOWED}" 1 " ${gip}:443 ")"
up="$(upstream_of "${log}")"; note "response ${hdr:-<none>}; upstream used by the sidecar: ${up}"
expect_eq "the sidecar connected to GitHub, not to the dialed IP" "server: github.com" "${hdr}"
expect_no_match "upstream is not ${gip}" "^${gip}:" "${up}"

step "Silent error: the same ServiceEntry with resolution: NONE (silent-errors/07-serviceentry-resolution-none.yaml)"
apply_scenario "${REPO_ROOT}/silent-errors/07-serviceentry-resolution-none.yaml"
wait_json 90 '.[0].type == "ORIGINAL_DST"' \
  ictl proxy-config cluster deploy/payments-api -n "${NS}" --fqdn "${ALLOWED}" -o json
mark
gip="$(pod_ip_of "${FORGOTTEN}")"
k -n "${NS}" exec deploy/payments-api -c app -- curl -sk -o /dev/null --max-time 8 \
  --resolve "${ALLOWED}:443:${gip}" "https://${ALLOWED}/" || true
log="$(sidecar_log "outbound|443||${ALLOWED}" 1 "\"${gip}:443\" ")"
up="$(upstream_of "${log}")"; note "access log: ${log:0:200}"
expect_eq "the sidecar forwarded to the dialed IP (${FORGOTTEN}), logged as ${ALLOWED}" "${gip}:443" "${up}"

step "Restore: ServiceEntry removed, ALLOW_ANY, CoreDNS query log off"
reset_policies "${NS}"
ictl install -y -f "${REPO_ROOT}/istio/install.yaml" 2>&1 | tail -1 | sed 's/^/    /'
bash "${REPO_ROOT}/egress/coredns-query-log.sh" off "${KUBE_CONTEXT}" | sed 's/^/    /'
expect_eq "mesh config back to" "ALLOW_ANY" "$(mesh_mode)"
wait_ext 90 "${NS}" "${FORGOTTEN}" "200 0" || true
expect_eq "${FORGOTTEN} reachable again" "200 0" "$(ext "${NS}" "${FORGOTTEN}")"
finish
