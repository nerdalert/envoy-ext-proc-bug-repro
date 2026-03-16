# Envoy Ext-Proc Chain Bug: BBR + EPP Validation

Validation of [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654) — the
end-of-stream (EoS) bug when two `ext_proc` filters are chained in Envoy. Tracked by
[gateway-api-inference-extension#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115).

The fix is [envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175), backported to
Envoy 1.37 and included in Istio 1.29.1 via [istio/proxy#6843](https://github.com/istio/proxy/pull/6843).

## TL;DR

**The fix does not resolve the bug for the real BBR + EPP deployment.**

- Istio 1.28.1 (no fix): 18/100 full responses, 82 truncated or empty
- Istio 1.29.1 (with fix): 11/100 full responses, 89 truncated or empty

Tested with BBR (`main`) + EPP (`v1.4.0-rc.2`) + vLLM simulator, using 8KB request bodies with
streaming responses. The fix (PR #43175) is confirmed present in the 1.29.1 binary but does not
cover the timing variant that occurs when both filters use `FULL_DUPLEX_STREAMED` mode.

## What happens

1. Client sends an 8KB request body. Envoy sets `observed_decode_end_stream_ = true`.
2. BBR (ext_proc filter 1, `FULL_DUPLEX_STREAMED`) processes the body via its gRPC server and
   injects it back into the filter chain chunk by chunk.
3. The injected data hits EPP (ext_proc filter 2, also `FULL_DUPLEX_STREAMED`). EPP triggers its
   own async gRPC call. The filter chain stops.
4. EPP's gRPC response arrives. It calls `commonContinue()` which checks:
   ```cpp
   doData(observedEndStream() && !had_trailers_before_data);
   ```
   `observedEndStream()` returns `true` — set at step 1 when client data arrived.
5. If BBR hasn't finished injecting all its data, `doData(true)` sends partial data to the
   backend with `end_of_stream=true`. The backend receives a truncated request and returns a
   truncated response.

The fix (PR #43175) updates `observed_decode_end_stream_` during `injectDecodedDataToFilterChain`.
But it only helps if BBR's inject happens **before** EPP calls `commonContinue()`. With both
filters in `FULL_DUPLEX_STREAMED`, the timing is unpredictable — sometimes the inject wins,
sometimes `commonContinue()` wins.

## Deployment

### Prerequisites

- kind, kubectl, helm
- istioctl 1.28.1 and 1.29.1

### Deploy the stack

```bash
# Create cluster
kind create cluster --name igw-validate

# Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

# Inference Extension CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/crd/bases/inference.networking.k8s.io_inferencepools.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/crd/bases/inference.networking.x-k8s.io_inferencepoolimports.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/crd/bases/inference.networking.x-k8s.io_inferencepools.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/crd/bases/inference.networking.x-k8s.io_inferencemodelrewrites.yaml

# Istio (use 1.28.1 to reproduce, 1.29.1 to validate fix)
ISTIO_VERSION=1.28.1
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
./istio-${ISTIO_VERSION}/bin/istioctl install \
  --set profile=minimal \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
  --set meshConfig.enableAutoMtls=false \
  -y

# Gateway
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/gateway/istio/gateway.yaml

# vLLM simulator
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/vllm/sim-deployment.yaml

# BBR adapter configmap
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/bbr/configmap.yaml

# EPP v1.4.0-rc.2 + InferencePool (provider=istio)
helm install vllm-llama3-8b-instruct \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=istio \
  --set experimentalHttpRoute.enabled=true \
  --set inferenceExtension.image.tag=v1.4.0-rc.2 \
  --version v1.4.0-rc.2 \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool

# BBR from main (provider=istio)
helm install body-based-router \
  --set provider.name=istio \
  --version v0 \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/body-based-routing

# InferenceObjective
kubectl apply -f - <<EOF
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: llama-base
spec:
  priority: 2
  poolRef:
    name: vllm-llama3-8b-instruct
EOF

# Wait for pods
kubectl rollout status deploy/vllm-llama3-8b-instruct deploy/body-based-router --timeout=120s
```

### Verify images

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
kubectl exec deploy/inference-gateway-istio -c istio-proxy -- /usr/local/bin/envoy --version
```

Expected:
- `istio/proxyv2:1.28.1` or `1.29.1`
- `bbr:main`
- `epp:v1.4.0-rc.2`
- `llm-d-inference-sim:v0.7.1`

### Verify the fix and runtime guard (1.29.1 only)

The fix adds runtime feature `ext_proc_inject_data_with_state_update` to `runtime_features.cc`.
It is a `RUNTIME_GUARD` (enabled by default). Verify it is active on the running proxy:

```bash
# Explicitly enable (idempotent — it's already on by default via RUNTIME_GUARD)
kubectl exec deploy/inference-gateway-istio -c istio-proxy -- \
  curl -s -X POST "localhost:15000/runtime_modify?envoy.reloadable_features.ext_proc_inject_data_with_state_update=true"

# Confirm it's enabled
kubectl exec deploy/inference-gateway-istio -c istio-proxy -- \
  curl -s localhost:15000/runtime | grep -A 5 ext_proc
```

Expected output:
```
  "envoy.reloadable_features.ext_proc_inject_data_with_state_update": {
   "layer_values": [
    "",
    "true"
   ],
   "final_value": "true"
```

Verify via envoy source that the feature exists in 1.29.1 but not 1.28.1:

```bash
# 1.29.1 has it:
gh api repos/envoyproxy/envoy/contents/source/common/runtime/runtime_features.cc?ref=f8e895d391b2566e0674d782625219388c703ae1 \
  | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())" \
  | grep ext_proc_inject_data_with_state_update

# 1.28.1 does not:
gh api repos/envoyproxy/envoy/contents/source/common/runtime/runtime_features.cc?ref=79ef833c1b953c6686afda8636cc2bc073669994 \
  | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())" \
  | grep ext_proc_inject_data_with_state_update
```

## Reproduce the bug

### Setup

```bash
GW_PORT=$(kubectl get svc inference-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
GW_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
ENDPOINT="http://$GW_IP:$GW_PORT/v1/chat/completions"

# Generate 8KB request body
dd if=/dev/zero bs=1 count=8000 2>/dev/null | tr '\0' 'x' > /tmp/pad.txt
printf '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"system","content":"' > /tmp/big.json
cat /tmp/pad.txt >> /tmp/big.json
printf '"},{"role":"user","content":"Hi"}],"max_tokens":500,"stream":true}' >> /tmp/big.json
```

### Test 1: Small body, non-streaming (passes — no truncation)

```bash
curl -s -o /dev/null -w "HTTP %{http_code} size=%{size_download}\n" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"Hi"}],"max_tokens":500}'
```

### Test 2: Large body + streaming (fails — truncation)

Full response should be ~130KB. Most will be truncated:

```bash
# Single request
curl -s -o /dev/null -w "size=%{size_download}\n" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d @/tmp/big.json

# Run 10 times — most will be truncated
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "size=%{size_download}\n" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d @/tmp/big.json --max-time 30
done
```

Example output (full response is ~130KB, anything less is truncated):

```
size=7866
size=5956
size=135161
size=6244
size=11090
size=0
size=10506
size=135282
size=7851
size=840
```

### Test 3: Load test (50 concurrent)

```bash
rm -f /tmp/igw_results.txt
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code} %{size_download}\n" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d @/tmp/big.json --max-time 60 >> /tmp/igw_results.txt &
done
wait
echo "Full (>100KB): $(awk '$2 > 100000' /tmp/igw_results.txt | wc -l)/50"
echo "Truncated: $(awk '$2 > 0 && $2 < 100000' /tmp/igw_results.txt | wc -l)/50"
echo "Empty: $(awk '$2 == 0' /tmp/igw_results.txt | wc -l)/50"
```

### Switch Istio versions

To test 1.29.1 (with fix) instead of 1.28.1:

```bash
ISTIO_VERSION=1.29.1
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
./istio-${ISTIO_VERSION}/bin/istioctl install \
  --set profile=minimal \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
  --set meshConfig.enableAutoMtls=false \
  -y

# Restart gateway to pick up new proxy (may need two restarts)
kubectl rollout restart deploy/inference-gateway-istio
kubectl rollout status deploy/inference-gateway-istio --timeout=120s

# Verify version changed
kubectl exec deploy/inference-gateway-istio -c istio-proxy -- /usr/local/bin/envoy --version
```

## Results

| | Istio 1.28.1 (Envoy 1.36.3-dev) | Istio 1.29.1 (Envoy 1.37.1-dev) |
|---|---|---|
| Full responses (>100KB) | 18/100 | 11/100 |
| Truncated (1-100KB) | 73/100 | 66/100 |
| Empty (0 bytes) | 9/100 | 23/100 |
| **Total failures** | **82%** | **89%** |

Configuration: BBR `main` + EPP `v1.4.0-rc.2` + vLLM sim `v0.7.1`, 8KB request body,
`stream:true`, 100 concurrent requests.

## Why the fix doesn't work here

PR [#43175](https://github.com/envoyproxy/envoy/pull/43175) updates `observed_decode_end_stream_`
during `injectDecodedDataToFilterChain()`. This works when the body inject happens **before** the
second filter resumes. The upstream integration test validates exactly that ordering.

But BBR + EPP both use `FULL_DUPLEX_STREAMED`. Both filters process the same data concurrently.
Whether BBR's inject or EPP's `commonContinue()` fires first is a race — determined by gRPC
response timing, event loop scheduling, and system load. The fix helps when BBR wins the race.
It doesn't help when EPP wins.

[@wbpcode](https://github.com/wbpcode) (Envoy maintainer) identified the deeper issue in
[envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654): `commonContinue()` uses
a stream-level `observedEndStream()` flag instead of per-filter state. He proposed refactoring to
per-filter end_stream tracking but cautioned *"we need to evaluate the side effect very carefully
because the state machine of filter chain is very very complex."* No code was written for this
proposal.

## References

- [envoyproxy/envoy#41654](https://github.com/envoyproxy/envoy/issues/41654) — Original bug report
- [envoyproxy/envoy#43175](https://github.com/envoyproxy/envoy/pull/43175) — Fix (covers partial timing only)
- [gateway-api-inference-extension#2115](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2115) — IGW tracking issue
- [istio/proxy#6843](https://github.com/istio/proxy/pull/6843) — Envoy dependency update in Istio 1.29
