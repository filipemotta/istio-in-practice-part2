#!/usr/bin/env bash
# resilience-lint: offline checks for Istio resilience and egress manifests,
# meant for CI. Usage: ci/resilience-lint.sh <dir or file>...
#
# Two layers, both without a cluster:
#  1. istioctl analyze --use-kube=false --all-namespaces on the files
#     (without --all-namespaces offline analysis only looks at "default").
#  2. Static checks (yq -> JSON, jq) for mistakes the API server and
#     istioctl analyze accept, each one reproduced in the lab:
#     - VirtualService rule with a fault AND a timeout or retries: the
#       injected delay is not covered by the timeout and injected aborts are
#       never retried, so the "test" proves nothing (inject on the next hop);
#     - retries without a route timeout: no total time budget;
#     - perTryTimeout >= timeout: no retry can start after a slow try;
#     - outlierDetection whose maxEjectionPercent (default 10) is below
#       100 / endpoints: Envoy ejects only if (ejected + 1) / endpoints fits,
#       so nothing is ever ejected. Endpoints = replicas of the Deployments
#       selected by the Service in the analyzed set; without them, an omitted
#       maxEjectionPercent is reported (10% needs at least 10 endpoints);
#     - HTTPRoute retry: experimental in Gateway API v1.6, not in the standard
#       CRDs (rejected under strict validation, silently dropped otherwise);
#     - ServiceEntry resolution NONE for MESH_EXTERNAL hosts: the proxy
#       forwards to whatever IP the client dialed;
#     - outboundTrafficPolicy REGISTRY_ONLY together with ambient namespaces:
#       ztunnel does not enforce it;
#     - the same Service targeted by a VirtualService and a mesh HTTPRoute.
# Not detectable offline: a mesh timeout looser than the application's own
# timeout (the lint cannot see the client code). The lab proves that one.
# Analyze the whole set that is applied together: cross-resource checks only
# see the files they are given. Exits 1 on any finding.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <dir or file>..." >&2
  exit 2
fi
for tool in istioctl yq jq; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}: run tools/install-cli.sh (jq: install it)" >&2; exit 2; }
done

files=()
for arg in "$@"; do
  if [ -d "${arg}" ]; then
    while IFS= read -r f; do files+=("${f}"); done \
      < <(find "${arg}" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  else
    files+=("${arg}")
  fi
done
if [ "${#files[@]}" -eq 0 ]; then
  echo "no YAML files found in: $*" >&2
  exit 2
fi

status=0

# istioctl analyze only understands Kubernetes/Istio resources; the
# IstioOperator install files are checked by the static layer only.
kfiles=()
for f in "${files[@]}"; do
  if [ "$(yq 'select(.kind == "IstioOperator") | .kind' "${f}" 2>/dev/null)" = "" ]; then kfiles+=("${f}"); fi
done
echo "== istioctl analyze --use-kube=false --all-namespaces (${#kfiles[@]} files)"
if [ "${#kfiles[@]}" -gt 0 ] && ! istioctl analyze --use-kube=false --all-namespaces "${kfiles[@]}" 2>&1; then
  status=1
fi

echo "== static resilience checks"
docs=""
for f in "${files[@]}"; do
  if ! one="$(yq -o=json -I=0 '.' "${f}" | jq -c --arg file "${f}" 'select(. != null) | {file: $file, doc: .}')"; then
    echo "ERROR ${f}: not parseable as YAML"
    status=1
    continue
  fi
  docs+="${one}"$'\n'
done

# shellcheck disable=SC2016 # jq program, not shell
findings="$(jq -r -s '
  def ns: .metadata.namespace // "default";
  def fqdn($n; $ns):
    if ($n | test("\\*")) then $n
    elif ($n | contains(".") | not) then "\($n).\($ns).svc.cluster.local"
    elif ($n | split(".") | length) == 2 then "\($n).svc.cluster.local"
    else $n end;
  def id: "\(.kind) \(ns)/\(.metadata.name)";
  # Gateway API / Istio durations: 500ms, 1s, 1m30s, 0.5s -> seconds
  def secs: if . == null then null else
    [scan("([0-9.]+)(h|ms|m|s)") | (.[0] | tonumber) * ({"h": 3600, "m": 60, "s": 1, "ms": 0.001}[.[1]])] | add end;
  def mesh_service_parents: [(.spec.parentRefs // [])[] | select(.kind == "Service" and ((.group // "") == ""))];
  def vs_applies_to_mesh: ((.spec.gateways // []) | length == 0) or any((.spec.gateways // [])[]; . == "mesh");
  def selects($sel; $labels): ($sel | length) > 0 and ($sel | to_entries | all(.value == $labels[.key]));

  [ .[] | .doc ] as $docs
  | . as $all
  # endpoints per Service FQDN: replicas of the Deployments its selector matches
  | [ $docs[] | select(.kind == "Service") | . as $svc
      | { key: fqdn($svc.metadata.name; $svc | ns),
          value: ( [ $docs[] | select(.kind == "Deployment" and (ns) == ($svc | ns))
                     | select(selects($svc.spec.selector // {}; .spec.template.metadata.labels // {}))
                     | (.spec.replicas // 1) ] ) } ]
    | map(select(.value | length > 0) | .value |= add) | from_entries as $endpoints
  | [ $all[] | select(.doc.kind == "HTTPRoute") | .doc as $d
      | ($d | mesh_service_parents[] | {host: fqdn(.name; (.namespace // ($d | ns))), id: ($d | id)}) ] as $hr_hosts
  | ([ $docs[] | select(.kind == "IstioOperator") | .spec.meshConfig.outboundTrafficPolicy.mode // empty ] | last) as $outbound
  | [ $all[] | .file as $file | .doc as $d
      | if $d.kind == "VirtualService" then
          ( ($d.spec.http // []) | to_entries[] | .key as $i | .value as $r
            | ( if $r.fault != null and ($r.timeout != null or $r.retries != null)
                then "\($file): \($d | id): http rule #\($i) has a fault and a \(if $r.timeout != null then "timeout" else "retry policy" end) on the same rule: the injected delay is not covered by the timeout and injected aborts are never retried; inject the fault on the next hop"
                else empty end ),
              ( if (($r.retries.attempts // 0) > 0) and $r.timeout == null
                then "\($file): \($d | id): http rule #\($i) retries without a route timeout: there is no total time budget for the \($r.retries.attempts + 1) tries"
                else empty end ),
              ( if ($r.retries.perTryTimeout != null) and ($r.timeout != null)
                   and (($r.retries.perTryTimeout | secs) >= ($r.timeout | secs))
                then "\($file): \($d | id): http rule #\($i) perTryTimeout \($r.retries.perTryTimeout) >= timeout \($r.timeout): a slow try uses the whole budget and no retry can start"
                else empty end ) ),
          ( if ($d | vs_applies_to_mesh) then
              ($d.spec.hosts // [])[] | fqdn(.; $d | ns) as $h
              | $hr_hosts[] | select(.host == $h)
              | "\($file): \($d | id): host \($h) is also the parent of \(.id): a VirtualService and an HTTPRoute on the same Service is undefined behavior"
            else empty end )
        elif $d.kind == "DestinationRule" then
          fqdn($d.spec.host; $d | ns) as $h
          | ( [ {where: "trafficPolicy", tp: $d.spec.trafficPolicy} ]
              + [ ($d.spec.subsets // [])[] | {where: "subset \(.name)", tp: .trafficPolicy} ] )[]
          | select(.tp.outlierDetection != null) | .where as $w
          | (.tp.outlierDetection.maxEjectionPercent // 10) as $max
          | if $endpoints[$h] != null then
              ($endpoints[$h]) as $n
              | if $n > 0 and (100 / $n) > $max
                then "\($file): \($d | id): \($w) outlierDetection maxEjectionPercent \($max)\(if .tp.outlierDetection.maxEjectionPercent == null then " (default)" else "" end) with \($n) endpoint(s) of \($h): one ejection is \((100 / $n) | floor)%, so no endpoint is ever ejected (needs >= \((100 / $n) | ceil))"
                else empty end
            elif .tp.outlierDetection.maxEjectionPercent == null
            then "\($file): \($d | id): \($w) outlierDetection without maxEjectionPercent: the default 10% ejects nothing with fewer than 10 endpoints"
            else empty end
        elif $d.kind == "HTTPRoute" then
          ($d.spec.rules // []) | to_entries[] | select(.value.retry != null)
          | "\($file): \($d | id): rule #\(.key) uses retry, which is experimental in Gateway API v1.6 and not in the standard CRDs (rejected by strict validation, silently dropped without it)"
        elif $d.kind == "ServiceEntry" then
          if ($d.spec.resolution // "NONE") == "NONE" and ($d.spec.location // "MESH_EXTERNAL") == "MESH_EXTERNAL"
             and any(($d.spec.hosts // [])[]; test("\\*") | not)
          then "\($file): \($d | id): resolution NONE for \(($d.spec.hosts // []) | join(",")): the proxy forwards to whatever IP the client dialed; use resolution DNS"
          else empty end
        elif $d.kind == "Namespace" and ($outbound == "REGISTRY_ONLY")
             and (($d.metadata.labels // {})["istio.io/dataplane-mode"] == "ambient") then
          "\($file): Namespace \($d.metadata.name): outboundTrafficPolicy REGISTRY_ONLY is not enforced for ambient workloads (ztunnel lets their egress through)"
        else empty end ]
  | .[]' <<< "${docs}")"
jq_rc=$?
# Fail closed: a broken check must not look like a clean result.
if [ "${jq_rc}" -ne 0 ]; then
  echo "ERROR static checks could not run (jq exit ${jq_rc})"
  status=1
fi

if [ -n "${findings}" ]; then
  while IFS= read -r line; do echo "ERROR ${line}"; done <<< "${findings}"
  status=1
else
  echo "no resilience findings"
fi

[ "${status}" -eq 0 ] && echo "resilience-lint: PASS" || echo "resilience-lint: FAIL"
exit "${status}"
