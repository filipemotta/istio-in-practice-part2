# istio-in-practice-part2

Companion repository for *Istio, Hands-On, Part 2*: time budgets, breaking
things on purpose, and where your traffic leaves the mesh.

The story continues on the payments platform of Part 1. `payments-api` calls
`fraud-check`, which calls `risk-score`. During a peak `fraud-check` gets slow
and starts failing; the question is how much time and how many attempts each
call may spend, whether the policy written in YAML does what it says, and where
the pods send traffic outside the cluster. Everything runs on a local `kind`
cluster, at zero cost, with assertions that count what actually happened:
response codes, milliseconds, requests that reached `fraud-check`, Envoy stats,
Prometheus series, Jaeger spans and Kiali edges.

Each policy is shown with the API that has it:

| Policy | Gateway API (standard v1.6) | Istio API |
|---|---|---|
| Route timeout | `HTTPRoute` `timeouts.request` | `VirtualService` `timeout` |
| Retries | not in the standard channel (`retry` is experimental) | `VirtualService` `retries` |
| Connection pool (concurrency limit) | none | `DestinationRule` `connectionPool` |
| Outlier detection (ejection) | none | `DestinationRule` `outlierDetection` |
| Fault injection | none | `VirtualService` `fault` |
| External hosts | none | `ServiceEntry`, mesh config `outboundTrafficPolicy` |

The same control plane serves a **sidecar** namespace (`payments`) and an
**ambient** namespace (`payments-ambient`, with a waypoint), so both data plane
modes are tested with the same policies.

## Pinned versions

| Component | Version |
|---|---|
| Istio | 1.31.1, `ambient` profile (istiod + istio-cni + ztunnel) |
| Gateway API CRDs | v1.6.0, standard channel (`standard-install.yaml`) |
| Observability addons | `samples/addons` of Istio 1.31.1: Prometheus v3.10.0, Grafana 12.0.1, Jaeger 2.17.0, Kiali v2.31 |
| kind | v0.32.0 (node image `kindest/node:v1.36.1`) |
| kubectl | v1.36.1 (downloaded into `./bin`) |
| yq | v4.54.1 (mikefarah/yq, downloaded into `./bin`, SHA-256 checked) |
| promtool | 3.10.0 (from the Prometheus release, downloaded into `./bin`, SHA-256 checked; same version as the addon Prometheus) |
| Demo images | `fortio/fortio:1.75.3` (fraud-check, risk-score, load generator), `curlimages/curl:8.22.0` (payments-api) |

## Prerequisites

- Docker with about 4 CPUs and 6 GB available (Docker Desktop, Colima or Linux).
- `kind` v0.32.0, `jq`, `curl`, `tar`; `shellcheck` and `kubeconform` for `validate.sh`.
- macOS or Linux, arm64 or amd64, with Internet access: images, release
  manifests, and the egress step calls `https://api.github.com` and
  `https://www.google.com` from inside the cluster.
- `istioctl`, `kubectl`, `yq` and `promtool` are downloaded by `tools/install-cli.sh` into
  `./bin`. Every script passes `--context kind-istio-p2` and refuses to run if
  that context does not point at a local kind API server: the lab never uses
  your current kubectl context. `egress/coredns-query-log.sh` has the same
  guard (it rewrites the CoreDNS ConfigMap). `egress/inventory.sh` is
  read-only and has no guard on purpose, so you can point it at your own
  cluster: it always passes `--context` (default `kind-istio-p2`), never your
  current context.

## The workloads

- **payments-api**: the caller. Its `app` container is curl, standing in for the
  service code: `curl --max-time` is the application timeout and `curl --retry`
  is the client library retry. Its `load` container is fortio, used as a
  concurrent load generator.
- **fraud-check**: 2 replicas of the fortio echo server. Latency and errors come
  from the query string of each request: `?delay=3s`, `?status=503`,
  `?status=503:50` (half of the time). With `-loglevel Verbose` it logs one line
  per request, which is how the lab counts the attempts that reached it. Port
  8090 is fraud-check calling `risk-score` (fortio's `-M` proxy forwards path,
  query, headers and trace context).
- **fraud-check-degraded**: one more replica behind the same Service, scaled to 0
  except in the outlier detection step. It answers 503 to every request without
  a query string, while its readiness probe keeps passing.
- **risk-score**: the dependency of fraud-check, same fortio echo server.

## Layout

```
tools/install-cli.sh            pinned istioctl, kubectl, yq and promtool into ./bin
tools/gen-ambient-apps.sh       regenerates apps/payments-ambient.yaml from the sidecar one
kind/cluster.yaml               1 control plane + 2 workers
istio/install.yaml              IstioOperator: ambient profile, access logs, tracing to Jaeger,
                                ALLOW_ANY written out, extra Envoy stats (retry, overflow, outlier)
observability/telemetry.yaml    Telemetry: tracing to Jaeger, 100% sampling (lab only)
observability/alerts.yaml       Prometheus alerting rules on response flags: NR, NC, UH, BlackHoleCluster,
                                UO, URX, UT, DC (loaded into the addon Prometheus by step 01)
observability/alerts_test.yaml  promtool unit tests for those rules
observability/alert-drill-routes.yaml   two broken routes (NR, NC) used to fire the alerts in step 05
observability/stats-probe.yaml  a second caller whose sidecar keeps Istio's default stats list
apps/                           the workloads above, in "payments" (sidecar) and "payments-ambient"
timeouts/virtualservice/        1s route timeout, Istio API
timeouts/gateway-api/           1s route timeout, HTTPRoute
retries/virtualservice/         timeout 2s, attempts 2, perTryTimeout 500ms, gateway errors only
circuit-breaking/               connectionPool (overflow -> 503) and outlierDetection (ejection)
fault-injection/                abort and delay on fraud-check -> risk-score (one hop below the policy)
egress/                         REGISTRY_ONLY overlay, ServiceEntry (resolution DNS), outbound
                                inventory script, CoreDNS query log toggle
ambient/                        waypoint + the same policies for payments-ambient
silent-errors/                  manifests the API server accepts and that do not do what they seem to
scripts/01-cluster.sh .. 07-ambient.sh   one step of the article each, with assertions
scripts/test-all.sh             runs the offline tests in ci/, then 01..07; non-zero exit on any failure
scripts/teardown.sh             deletes the kind cluster
ci/resilience-lint.sh           offline checks for CI (istioctl analyze + static checks)
ci/test-resilience-lint.sh      tests for the lint: working scenarios pass, silent errors fail
ci/testdata/                    extra lint fixtures
ci/test-alerts.sh               promtool check + unit tests of the alert rules, and mutants they must reject
ci/test-context-guard.sh        every lab step refuses a context that is not a local kind cluster
.github/workflows/resilience-lint.yml   GitHub Actions example running the offline tests
validate.sh                     static checks: bash -n, shellcheck, kubeconform
```

## Running

```bash
bash tools/install-cli.sh        # optional, the scripts call it
bash scripts/test-all.sh         # offline tests first; about 13 minutes from no cluster, 8 on an existing one
```

Or one step at a time, in the order of the article:

```bash
bash scripts/01-cluster.sh            # cluster, CRDs, Istio, addons, workloads, waypoint
bash scripts/02-timeouts.sh           # time budget: default, VirtualService, HTTPRoute, silent errors
bash scripts/03-retries.sh            # retries counted at fraud-check, amplification, HTTPRoute retry
bash scripts/04-circuit-breaking.sh   # connectionPool overflow, outlierDetection and maxEjectionPercent
bash scripts/05-fault-injection.sh    # faults one hop below the policy; Prometheus, Jaeger, Kiali, Grafana
bash scripts/06-egress.sh             # ALLOW_ANY, inventory, REGISTRY_ONLY, ServiceEntry DNS vs NONE
bash scripts/07-ambient.sh            # the same policies through the waypoint
```

Measured on a laptop (Docker with 5 CPUs, kind v0.32.0): 791 s from no cluster,
464 s on the cluster of a previous run. Steps 05 and 06 keep failing traffic
going until Prometheus reports the alerts (about one minute measured, up to 5).

Steps 02 to 07 delete the policies of the namespace they use before and after
running, so they can be repeated once step 01 is done. Step 06 switches the
mesh to `REGISTRY_ONLY` and restores `ALLOW_ANY` at the end (and at the start,
if a previous run stopped half-way). Step 05 reads Prometheus series written by
step 04, so run 04 before 05.

To try a policy by hand:

```bash
export PATH="$PWD/bin:$PATH"
kubectl --context kind-istio-p2 apply -f retries/virtualservice/fraud-check-retries.yaml
kubectl --context kind-istio-p2 -n payments exec deploy/payments-api -c app -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' 'http://fraud-check:8080/try1?status=503'
kubectl --context kind-istio-p2 -n payments logs -l app=fraud-check -c fortio --since=1m | grep -c '/try1'
```

The last command prints 3: one call and two retries.

The dashboards, with port-forwards through istioctl:

```bash
istioctl --context kind-istio-p2 dashboard grafana     # Istio Service / Workload dashboards
istioctl --context kind-istio-p2 dashboard jaeger      # service payments-api.payments
istioctl --context kind-istio-p2 dashboard kiali       # graph of the payments namespace
istioctl --context kind-istio-p2 dashboard prometheus
```

## What the steps check

- **01 Cluster**: istiod, one ztunnel per node, the standard Gateway API CRDs,
  the four addons, `ALLOW_ANY`, the workloads in both modes, and Prometheus
  serving the 8 rules of `observability/alerts.yaml`.
- **02 Timeouts**: no timeout by default (a 3s answer takes 3s); a 1s route
  timeout in each API (504 after about 1s, flag `UT`), while fraud-check still
  finishes the 3s of work; a 5s mesh timeout under a 2s application timeout
  never fires (the application gives up, the proxy logs `DC`);
  `x-envoy-upstream-rq-timeout-ms` sent by the application neither shortens nor
  lengthens the timeout, because the sidecar treats the application as an
  external client and strips `x-envoy-*` headers (no `internal_address_config`
  since Envoy 1.33); a delay injected on the same route as the timeout is not
  covered by it (200 after 3s, flag `DI`).
- **03 Retries**: the default policy pushed to every sidecar (2 retries on
  `connect-failure,refused-stream,unavailable,cancelled`) does not retry an
  application 503 (1 attempt); with the VirtualService, 3 attempts per call,
  `URX`; slow answers end in 504 after 3 tries of 500ms, inside the 2s budget; a
  50% failure rate becomes about 88% success at about 1.75x the load on
  fraud-check; `curl --retry 2` on top of mesh retries means 9 requests for one
  call; an `HTTPRoute` with `retry` is rejected by the standard CRDs, and created
  without it when validation is off.
- **04 Circuit breaking**: with 2 connections and 1 pending request allowed, 6
  concurrent callers get 503 (`UO`); each 503 is one `upstream_rq_pending_overflow`
  and none of them reached fraud-check. With one degraded replica out of 3, an
  `outlierDetection` without `maxEjectionPercent` (10%) or with 30% ejects
  nothing (one ejection is 33%) and counts `ejections_overflow`; with 50%, the
  replica is out after exactly 3 failures and shows `FAILED` in
  `istioctl proxy-config endpoint`. Its readiness probe kept passing the whole time.
  `stats-probe`, a caller whose sidecar keeps Istio's default stats inclusion
  list (no `proxyStatsMatcher`), gets the same 503s, but its Envoy has no
  `upstream_rq_pending_overflow` and no `outlier_detection` counter for
  fraud-check at all, not even in `pilot-agent request GET stats`.
- **05 Fault injection**: an abort on fraud-check -> risk-score tests the retries
  of payments-api -> fraud-check (3 aborts injected, risk-score never called); a
  3s delay there tests the perTryTimeout (504 after about 1.6s). The same fault on
  the route that carries the policy proves nothing: injected aborts are never
  retried (0 attempts) and injected delays are not covered by the timeout.
  Prometheus shows `FI`, `DI` and `UO` in `istio_requests_total` and the retry,
  overflow and ejection counters (none of them for `stats-probe`, whose
  overflows only show as `UO`); for the aborted calls `reporter="source"`
  counts each call once and `reporter="destination"` counts 3, one per try;
  Jaeger shows one server span per try; Kiali shows the failing edges,
  including the degraded replica. Then the alert drill: a route with no
  catch-all (404 `NR`), a route to an undefined subset (503 `NC`) and the
  connection pool (503 `UO`) until `IstioRouteNotFound`, `IstioClusterNotFound`
  and `IstioUpstreamOverflow` are pending or firing in Prometheus.
- **06 Egress**: with `ALLOW_ANY` both hosts answer and the sidecar logs them as
  `PassthroughCluster` with an IP and no hostname; `egress/inventory.sh` pairs
  those IPs with the names each pod resolved (CoreDNS query log). With
  `REGISTRY_ONLY` both are blocked (curl exit 35, `BlackHoleCluster`, `UH`) while
  in-mesh calls keep working, and `IstioEgressBlocked` goes pending (HTTPS to a
  denied host is in `istio_tcp_connections_opened_total`, not in
  `istio_requests_total`); the ambient namespace still reaches both hosts;
  a `ServiceEntry` with `resolution: DNS` brings back only `api.github.com`, and
  connects to GitHub even when the application dials another IP; with
  `resolution: NONE` the sidecar forwards to the dialed IP and logs it as
  `api.github.com`.
- **07 Ambient**: the HTTPRoute timeout through the waypoint; the same route
  without the waypoint label is still `Accepted` and ignored; VirtualService
  retries (Alpha) with the same 3 and 9 attempts; a fault one hop below; the
  connection pool and outlier detection enforced by the waypoint.

## What the lab measured

These are the outputs of my runs on Istio 1.31.1. Scenario figures come from
run 4 of the lab, with run 5 as the second run where two values are given; the
`stats-probe`, `reporter` and alert figures come from run 6, the final run
(224 of 224 assertions). The article summarises them; compare your own `out/`
files against them. Latencies are from kind on one laptop, so expect your
milliseconds to differ; the counts of tries should not.

### Timeouts (step 02)

- No policy: `?delay=3s` answered 200 after 3.005 s. The route pushed to the
  caller carried `timeout: 0s` (disabled).
- `VirtualService` `timeout: 1s`: 504 after 1.005 s. `HTTPRoute`
  `timeouts.request: 1s` (`Accepted: True`): 504 after 1.008 s. The caller's
  access log:

  ```
  caller access log: [...] "GET /r17915606748357?delay=3s HTTP/1.1" 504 UT response_timeout - "-" 0 24 1000 [...]
  ```

- Three seconds after the 504, fraud-check's own log showed the request
  finishing and answering 200.
- `x-envoy-upstream-rq-timeout-ms` sent by the application with 300 and with
  5000: both requests ended in a 504 after about 1 s, and fraud-check's
  `/debug` echo never saw the header.
- Mesh `timeout: 5s` under `curl --max-time 2`: curl exit 28 after 2.001 s,
  no HTTP status, and the caller's proxy logged:

  ```
  caller access log: [...] "GET /r17915606843876?delay=3s HTTP/1.1" 0 DC downstream_remote_disconnect - "-" 0 0 2001 [...]
  ```

### Retries (step 03)

- Default retry policy pushed to the caller, with no `VirtualService`:

  ```
  default retry policy pushed to the caller: {"numRetries":2,"retryOn":"connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes"}
  ```

  No status code is configured with `retriable-status-codes`, so an
  application 503 reached fraud-check once.
- With `retries/virtualservice/fraud-check-retries.yaml`: `?status=503`
  reached fraud-check 3 times and returned 503 after 35 ms, flag `URX`;
  `?delay=1s` ended in a 504 after 1.575 s (three tries of 500 ms).
- `?status=503:50`, 100 calls: 93 successes for 167 requests at fraud-check
  (second run: 90 for 170). Expected: 87.5% and 175.
- `curl --retry 2 --retry-delay 0.2` on top of the mesh retries: 9 requests at
  fraud-check for one failed call.
- `HTTPRoute` with `retry` on the standard CRDs of v1.6.0:

  ```
  Error from server (BadRequest): error when creating "silent-errors/04-httproute-retry-standard-channel.yaml": HTTPRoute in version "v1" cannot be handled as a HTTPRoute: strict decoding error: unknown field "spec.rules[0].retry"
  ```

  With `--validate=false` the stored rule had only `backendRefs`, `matches` and
  `timeouts`, and a 503 reached fraud-check once.

### Circuit breaking (step 04)

- Connection pool, 60 calls from 6 concurrent callers, 200 ms each: without the
  `DestinationRule` 60 succeeded; with it 33 succeeded and 27 got 503 `UO`
  (second run: 29 and 31). `upstream_rq_pending_overflow` on the caller went
  from 0 to 27; fraud-check served 33 requests and returned no 503.
- Degraded replica, no policy: 16 of 60 calls failed.
- `outlierDetection` with `maxEjectionPercent: 50`: 3 of 60 failed,
  `ejections_enforced_total` +1, and the caller's endpoint list:

  ```
      ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
      10.244.1.15:8080     HEALTHY     FAILED            outbound|8080||fraud-check.payments.svc.cluster.local
      10.244.1.9:8080      HEALTHY     OK                outbound|8080||fraud-check.payments.svc.cluster.local
      10.244.2.5:8080      HEALTHY     OK                outbound|8080||fraud-check.payments.svc.cluster.local
  ```

- Without `maxEjectionPercent` (default 10%): 19 of 60 failed, no ejection,
  `outlier_detection.ejections_overflow` reached 16 in Prometheus, and Kiali
  showed the edge to `fraud-check-degraded` at 100.0% errors. With 30%: 17 of
  60 failed, no ejection.
- `stats-probe` (default stats inclusion list): its connection pool rejected 37
  of 60 calls; its Envoy held 0 statistics for the fraud-check cluster, against
  11 on `payments-api`. The 37 overflows showed in Prometheus only as
  `response_flags="UO"`.

### Fault injection and observability (step 05)

- Fault on the same rule as the policy: a 3 s delay next to a 1 s timeout
  returned 200 after 3.016 s with `DI`; an abort next to the retries came back
  after 6 ms with one `FI` line, no `URX` and 0 requests at fraud-check.
- Abort one hop below: before the fault the two-hop call returned 200 in 18 ms;
  with it, 503 after 67 ms, `URX` at the caller, three `503 FI
  fault_filter_abort` lines in the fraud-check sidecar, nothing at risk-score.
- Delay one hop below: 504 after 1.578 s; the fraud-check sidecar logged three
  tries with `DI,DC` and the caller `504 URX,UT upstream_per_try_timeout`.
- Prometheus, after the fault tests:

  ```
  sum by (response_flags) (istio_requests_total{reporter="source", source_workload="fraud-check", destination_service_name="risk-score"})
  ```

  returned `-` 21, `FI` 153 and `DI,DC` 3.
- `reporter` ratio during the abort phase: `reporter="source"` on payments-api
  51 failed calls with `URX`, `reporter="destination"` on fraud-check 153
  failed tries, ratio 3.00 (asserted within 5%).
- Jaeger trace of one aborted call, in time order:

  ```
  fraud-check.payments.svc.cluster.local:8090/* http.status_code=503 response_flags=URX span.kind=client
  fraud-check.payments.svc.cluster.local:8090/* http.status_code=503 response_flags=- span.kind=server
  risk-score.payments.svc.cluster.local:8080/* http.status_code=503 response_flags=FI span.kind=client
  fraud-check.payments.svc.cluster.local:8090/* http.status_code=503 response_flags=- span.kind=server
  risk-score.payments.svc.cluster.local:8080/* http.status_code=503 response_flags=FI span.kind=client
  fraud-check.payments.svc.cluster.local:8090/* http.status_code=503 response_flags=- span.kind=server
  risk-score.payments.svc.cluster.local:8080/* http.status_code=503 response_flags=FI span.kind=client
  ```

- Kiali: payments-api to fraud-check at 34.8% errors, fraud-check to
  risk-score at 100.0%.
- Alert drill: after 63 s, `IstioRouteNotFound`, `IstioClusterNotFound` and
  `IstioUpstreamOverflow` were pending in the addon Prometheus. The lab does not
  wait out the `for` clauses; `ci/test-alerts.sh` covers them.

### Egress (step 06)

- `ALLOW_ANY`: both hosts answered 200, logged as passthrough with no SNI:

  ```
  [...] "4.228.31.149:443" PassthroughCluster 10.244.1.8:57708 4.228.31.149:443 10.244.1.8:57692 - -
  [...] "142.251.155.119:443" PassthroughCluster 10.244.1.8:35760 142.251.155.119:443 10.244.1.8:35744 - -
  ```

- `egress/inventory.sh`:

  ```
      pod payments-api-7998c54b8b-k8jqz (10.244.1.8)
        passthrough 4.228.31.149:443         connections=1
        passthrough 142.251.155.119:443      connections=1
        resolved    www.google.com           queries=2
        resolved    api.github.com           queries=2
  ```

- `REGISTRY_ONLY`: both hosts failed with curl exit 35; in-mesh calls kept
  answering 200; `IstioEgressBlocked` went pending:

  ```
  access log: [...] "- - -" 0 UH [...] BlackHoleCluster - 142.251.155.119:443 10.244.1.8:53770 - -
  ```

- `ServiceEntry` with `resolution: DNS`: `api.github.com` answered 200, logged
  as `"4.228.31.149:443" outbound|443||api.github.com [...] api.github.com`;
  `www.google.com` stayed blocked (exit 35). Dialing Google's IP with
  `--resolve api.github.com:443:142.251.155.119` reached `server: github.com`.
- The same with `resolution: NONE`: the sidecar forwarded to the dialed IP and
  logged it as GitHub:

  ```
  access log: [...] "142.251.155.119:443" outbound|443||api.github.com [...] api.github.com
  ```

### Ambient (step 07)

- `HTTPRoute` timeout through the waypoint: 504 after 1.025 s, `UT` in the
  waypoint's log. Without the `istio.io/use-waypoint` label: still
  `Accepted=True` with "istio.io/use-waypoint label missing from parent and
  parent namespace; in ambient mode, route will not be respected.", and 200
  after 3.010 s.
- `VirtualService` retries (Alpha in ambient): 3 requests at fraud-check, `URX`
  in the waypoint's log; 9 with `curl --retry 2` on top. The abort one hop below
  was injected three times by the waypoint and never reached risk-score.
- Connection pool: 32 of 60 rejected, `upstream_rq_pending_overflow` on the
  waypoint from 0 to 32.
- Outlier detection with 50%: from 23 failures in 60 calls to 3; the waypoint's
  endpoint list:

  ```
      envoy://connect_originate/10.244.1.18:8080     HEALTHY     FAILED            inbound-vip|8080|http|fraud-check.payments-ambient.svc.cluster.local
  ```

- `REGISTRY_ONLY`: the ambient `payments-api` reached both external hosts with
  200 while the sidecar pod got exit 35.

### Totals

Run 6, from no cluster: 224 of 224 assertions (58 offline + 166 lab), 791 s.
Run 7, on the existing cluster: 224 of 224, 464 s. Run 8, after scoping the
`NR` rule to east-west traffic: 225 of 225, 539 s (the extra assertion is the
new mutant).

## Resilience checks in CI (no cluster)

`ci/resilience-lint.sh <dir or file>...` fails the build on the mistakes above
that are visible in the manifests:

```bash
bash tools/install-cli.sh
bash ci/resilience-lint.sh apps/payments-sidecar.yaml silent-errors/05-dr-outlier-default-max-ejection.yaml
bash ci/test-resilience-lint.sh
```

It runs `istioctl analyze --use-kube=false --all-namespaces` and static checks
(yq + jq): a fault on the same VirtualService rule as a timeout or retries;
retries without a route timeout; `perTryTimeout` >= `timeout`; an
`outlierDetection` whose `maxEjectionPercent` is below 100 / endpoints (the
endpoints are counted from the Deployments the Service selects in the analyzed
set; without them an omitted value is reported); `retry` in an HTTPRoute
(experimental channel only); a `ServiceEntry` with `resolution: NONE`;
`REGISTRY_ONLY` with ambient namespaces; a VirtualService and an HTTPRoute on
the same Service. A mesh timeout looser than the application timeout is not
visible in manifests; step 02 is the test for it.

Lint the set of files applied together, with the workloads, so the endpoint
count is right.

The alert rules are tested offline too:

```bash
bash ci/test-alerts.sh            # promtool check rules + promtool test rules + mutants
bash ci/test-context-guard.sh     # the lab refuses any context that is not local kind
```

`observability/alerts.yaml` is a plain Prometheus rule file: the addon
Prometheus has no operator, and step 01 loads the file as the
`alerting_rules.yml` key of its ConfigMap.
`.github/workflows/resilience-lint.yml` runs all the offline tests on GitHub Actions.

## Teardown

```bash
bash scripts/teardown.sh
```

It deletes the `istio-p2` kind cluster. `./bin` and `./out` stay; delete them
by hand if you want.
