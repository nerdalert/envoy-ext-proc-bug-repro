# Envoy Ext-Proc Chain Bug Reproducer & Validation

Reproducer for [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654) — the
end-of-stream (EoS) interleaving bug when two `ext_proc` filters are chained in Envoy. This is
the bug tracked by [gateway-api-inference-extension#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115)
that affects **BBR + EPP** (body-based routing + endpoint picker protocol) in the Inference Gateway.

The fix is [envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175), backported to
Envoy 1.37 and included in Istio 1.29.1 via [istio/proxy#6843](https://github.com/istio/proxy/pull/6843).

## Bug Summary

When two `ext_proc` filters are in the same Envoy filter chain — one processing response body
in `FULL_DUPLEX_STREAMED` mode and one processing headers only — the `observedEndStream()` flag
in `filter_manager.cc` can become stale. When the header-only filter resumes via `commonContinue()`,
it uses the stale flag to pass `end_of_stream=true` before all body data has been re-injected,
causing **response truncation**.

**Symptoms:**
- HTTP 200 responses with truncated body (e.g., 3966 bytes instead of 51200)
- ext-proc server logs: `send error rpc error: code = Canceled desc = context canceled`

## Results

### Stage 1: Istio 1.28.1 (Envoy 1.36.3-dev) — Bug Reproduced

```
Results: ok=75 truncated=24 error=1 total=100
Truncated sizes: 47406 3966(x21) 18446 3966
extproc2 send errors: 100
```

### Stage 2: Istio 1.29.1 (Envoy 1.37.1-dev) — Fix Analysis

The fix ([envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175)) **is confirmed
present** in the 1.29.1 binary:

- Runtime feature `envoy_reloadable_features_ext_proc_inject_data_with_state_update` found in
  `runtime_features.cc` and enabled by default (`RUNTIME_GUARD`)
- Fix code verified in `filter_manager.cc` at both `injectEncodedDataToFilterChain` and
  `injectDecodedDataToFilterChain`
- Envoy commit `f8e895d3` (Feb 23, 2026) includes fix PR merged Feb 13, 2026

**Important nuance:** The fix updates the `observed_encode_end_stream_` flag during
`injectEncodedDataToFilterChain()`. This only helps when at least one body inject
happens *before* the header-only filter resumes. See [Timing Variants](#timing-variants)
for details.

## Timing Variants

The root cause is in `commonContinue()` at `filter_manager.cc:109,132`:

```cpp
// line 109 — headers path
doHeaders(observedEndStream() && !bufferedData() && !hasTrailers());

// line 132 — data path
if (bufferedData()) {
    doData(observedEndStream() && !had_trailers_before_data);
}
```

There are two timing variants of this race:

| Variant | Timing | Fix Covers? | Real-World Likelihood |
|---------|--------|-------------|----------------------|
| 1 | Body filter injects data **before** header-only filter resumes | **Yes** | High (body processing typically starts before header response arrives) |
| 2 | Header-only filter resumes **before** any body inject | No | Lower (requires header ext-proc to respond faster than body ext-proc) |

The upstream integration test (`TwoExtProcFiltersInResponseProcessing`) validates Variant 1.
Our reproducer with `body-delay=20ms` triggers Variant 2.

### Variant 1: Body injects first (fix works)

```
t=0   Backend response arrives, observedEndStream=true
t=1   Filter-1 sends body chunks to extproc2
t=2   extproc2 responds -> Filter-1 injects data with end_stream=false
      ^^^ FIX: observed_encode_end_stream_ updated to FALSE
t=3   More body injects (end_stream=false)...
t=4   extproc1 responds -> Filter-0 calls commonContinue()
      observedEndStream() returns FALSE (updated by fix at t=2)
      doData(false) -> partial body sent WITHOUT eos -> correct, stream stays open
t=5   Last body inject (end_stream=true) -> rest of body arrives -> complete response
```

### Variant 2: Header-only filter resumes first (fix does not help)

```
t=0   Backend response arrives, observedEndStream=true
t=1   Filter-1 sends body chunks to extproc2 (slow, e.g. 20ms delay each)
t=2   extproc1 responds -> Filter-0 calls commonContinue()
      ^^^ No body inject has happened yet! Fix never fired.
      observedEndStream() returns TRUE (stale, never updated)
      doHeaders(true) or doData(true) -> eos=true sent downstream -> TRUNCATION
t=3   extproc2 finally responds -> body inject attempted
      But downstream stream already closed -> "context canceled" errors
```

### Why Variant 2 remains unfixed

[@wbpcode](https://github.com/wbpcode) (Envoy maintainer) identified the deeper root cause in
[envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654#issuecomment-2604889989):
`commonContinue()` uses a **stream-level** `observedEndStream()` flag, but the correct behavior
requires a **per-filter** end-stream flag. He proposed a two-step refactor:

1. When a filter resumes, use a per-filter end_stream flag instead of the stream-level flag (fixes both variants)
2. Per-filter body buffers (larger refactor, not strictly needed for this bug)

Instead, PR [#43175](https://github.com/envoyproxy/envoy/pull/43175) took a narrower approach:
update the stream-level flag during `injectDataToFilterChain`. This fixes Variant 1 but leaves
Variant 2 unaddressed. The broader per-filter refactor was **never implemented** and there is
no open PR or issue tracking it.

## Reproducer Architecture

```
                    ┌──────────────┐
                    │   curl (50KB │
                    │   POST body) │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │    Envoy     │
                    │  (proxyv2)   │
                    │              │
                    │ ┌──────────┐ │     ┌──────────────┐
                    │ │ ext_proc │ │────▶│  extproc1     │
                    │ │ filter-0 │ │     │  (hdr-only)   │
                    │ │ hdr-only │ │◀────│  no delay     │
                    │ └──────────┘ │     └──────────────┘
                    │              │
                    │ ┌──────────┐ │     ┌──────────────┐
                    │ │ ext_proc │ │────▶│  extproc2     │
                    │ │ filter-1 │ │     │  (body proc)  │
                    │ │ FD_STREAM│ │◀────│  body-delay   │
                    │ └──────────┘ │     └──────────────┘
                    │              │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  echo server │
                    │  (echoes req │
                    │   body back) │
                    └──────────────┘
```

**Envoy filter config:**
- Filter-0 (`ext_proc_cluster_1`): `response_header_mode: SEND`, `response_body_mode: NONE`
- Filter-1 (`ext_proc_cluster_2`): `response_header_mode: SEND`, `response_body_mode: FULL_DUPLEX_STREAMED`

**Response direction** (reverse of config order): `router → Filter-1 → Filter-0`

## Quick Start

### Prerequisites

- Docker, kind, kubectl
- Go 1.24+ (for building ext-proc and echo images)

### Run the reproducer

```bash
# Create kind cluster
kind create cluster --name extproc-bug

# Build and load images
cd repro-extproc
docker build -t extproc-repro:latest -f extproc/Dockerfile extproc/
docker build -t echo-repro:latest -f echo/Dockerfile echo/
kind load docker-image extproc-repro:latest --name extproc-bug
kind load docker-image echo-repro:latest --name extproc-bug

# Load the Istio proxy image (use docker save for multi-arch images)
docker pull docker.io/istio/proxyv2:1.28.1
docker save docker.io/istio/proxyv2:1.28.1 | \
  docker exec -i extproc-bug-control-plane ctr --namespace=k8s.io images import -

# Deploy
kubectl apply -f manifests/repro.yaml
kubectl -n extproc-repro rollout status deploy/envoy --timeout=120s

# Get endpoint
NODEPORT=$(kubectl -n extproc-repro get svc envoy -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Run load test (50KB body, 100 concurrent requests)
BODY=$(python3 -c "print('A'*51200)")
rm -f /tmp/resp_*
for i in $(seq 1 100); do
  curl -s -o /tmp/resp_$i -X POST -d "$BODY" "http://$NODE_IP:$NODEPORT/test" --max-time 120 &
done
wait

# Check results
EXPECTED=51200
ok=0; trunc=0
for i in $(seq 1 100); do
  sz=$(wc -c < /tmp/resp_$i 2>/dev/null || echo 0)
  if [ "$sz" -eq "$EXPECTED" ]; then ok=$((ok+1)); else trunc=$((trunc+1)); fi
done
echo "ok=$ok truncated=$trunc total=100"
```

### Switch to 1.29.1

Edit `manifests/repro.yaml` and change the envoy image from `proxyv2:1.28.1` to `proxyv2:1.29.1`,
then redeploy and re-run the test.

## Ext-Proc Server Flags

The `extproc-repro` binary supports:

| Flag | Description |
|------|-------------|
| `-name` | Service name for log prefixes |
| `-grpcport` | gRPC listen port (default `:9902`) |
| `-body-delay` | Delay for body chunk responses (e.g., `20ms`) |
| `-hdr-delay` | Delay for response header responses (e.g., `50ms`) |

## File Layout

```
.
├── README.md
├── repro-extproc/
│   ├── extproc/          # ext-proc gRPC server (Go)
│   │   ├── main.go
│   │   ├── go.mod
│   │   └── Dockerfile
│   ├── echo/             # Echo HTTP server (Go)
│   │   ├── main.go
│   │   ├── go.mod
│   │   └── Dockerfile
│   └── manifests/
│       └── repro.yaml    # Full deployment manifest (ns, deployments, envoy config)
├── reports/
│   ├── 1.28.1-v2/        # Stage 1 results (bug reproduced)
│   └── 1.29.1-v2/        # Stage 2 results (fix analysis)
├── ISTIO-1.28.1-EXT-PROC-BUG-TRIGGER.md
├── ISTIO-1.29.1-EXT-PROC-BUG-TRIGGER.md
└── validate_istio_extproc_bug.sh
```

## Upstream History

| Date | Event |
|------|-------|
| 2025-10-28 | [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654) opened — ext_proc FULL_DUPLEX_STREAMED body truncated with multiple filters |
| 2026-01-09 | [gateway-api-inference-extension#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115) opened — BBR + EPP fails with long request body |
| 2026-01-10 | @yanjunxiang-google estimates ~2 weeks for fix |
| 2026-01-22 | [envoyproxy/envoy#43042](https://github.com/envoyproxy/envoy/pull/43042) — 1st fix attempt (superseded) |
| 2026-01-22 | [envoyproxy/envoy#43122](https://github.com/envoyproxy/envoy/pull/43122) — test stub PR (still open) |
| 2026-01-27 | [envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175) — 2nd fix attempt, updates `observed_encode_end_stream_` during `injectDataToFilterChain` |
| 2026-02-13 | PR #43175 merged to Envoy main |
| 2026-02-20 | [envoyproxy/envoy#43572](https://github.com/envoyproxy/envoy/pull/43572) — backport to Envoy release/v1.37 branch |
| 2026-02-23 | [istio/proxy#6843](https://github.com/istio/proxy/pull/6843) — Istio release-1.29 branch picks up Envoy commit `f8e895d3` (includes fix) |
| 2026-03-06 | Istio 1.29.1 released with the fix |
| 2026-03-12 | @nirrozenbaum asks @zetxqx to validate fix on 1.29.1 in [#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115) |
| 2026-03-16 | This repo: bug reproduced on 1.28.1; fix confirmed present in 1.29.1 source but Variant 2 timing still triggers truncation |

### Key upstream discussion

In [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654), @wbpcode described
the fundamental issue:

> *"When a filter continue the processing of filter chain, we use the per filter end_stream flag
> to determine whether the request is end stream rather than use the stream level flag. Then this
> problem should be resolved."*

He proposed refactoring `commonContinue()` to use per-filter state rather than the shared
`observed_encode_end_stream_` / `observed_decode_end_stream_` flags. This would fix both timing
variants. However, @yanjunxiang-google implemented the narrower ext_proc-scoped fix (PR #43175)
instead, which only addresses Variant 1.

The original issue #41654 was **auto-closed by stalebot**, then the fix was developed after
@yanjunxiang-google reopened work on it.

## References

- [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654) — Original bug report
- [envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175) — Fix (2nd attempt)
- [gateway-api-inference-extension#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115) — IGW tracking issue
- [istio/proxy#6843](https://github.com/istio/proxy/pull/6843) — Envoy dependency update in Istio 1.29 branch
