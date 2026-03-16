#!/usr/bin/env bash
set -euo pipefail

ISTIO_VERSION="${1:-}"
if [[ -z "${ISTIO_VERSION}" ]]; then
  echo "usage: $0 <istio-version>"
  exit 1
fi

CLUSTER_NAME="igw-bug-${ISTIO_VERSION//./-}"
REPORT_DIR="/tmp/igw-bug-report-${ISTIO_VERSION}"
mkdir -p "${REPORT_DIR}"

cleanup() {
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

kind create cluster --name "${CLUSTER_NAME}" --image kindest/node:v1.30.13 >/dev/null
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml >/dev/null

mkdir -p /tmp/istio-bin/${ISTIO_VERSION}
curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-amd64.tar.gz" -o "/tmp/istioctl-${ISTIO_VERSION}.tgz"
tar -xzf "/tmp/istioctl-${ISTIO_VERSION}.tgz" -C "/tmp/istio-bin/${ISTIO_VERSION}"
ISTIOCTL="/tmp/istio-bin/${ISTIO_VERSION}/istioctl"
chmod +x "${ISTIOCTL}"
"${ISTIOCTL}" install -y --set profile=demo --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true --set values.pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true >/dev/null

kubectl apply -k https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd >/dev/null
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/vllm/sim-deployment.yaml >/dev/null
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/gateway/istio/gateway.yaml >/dev/null

helm upgrade -i vllm-llama3-8b-instruct \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=istio \
  --set inferencePool.modelServerType=vllm \
  --set experimentalHttpRoute.enabled=true \
  --version v0 \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool >/dev/null

helm upgrade -i body-based-router \
  --set provider.name=istio \
  --version v0 \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/body-based-routing >/dev/null

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/main/config/manifests/bbr/configmap.yaml >/dev/null

helm upgrade vllm-llama3-8b-instruct \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama3-8b-instruct \
  --set provider.name=istio \
  --set inferencePool.modelServerType=vllm \
  --set experimentalHttpRoute.enabled=true \
  --set experimentalHttpRoute.baseModel=meta-llama/Llama-3.1-8B-Instruct \
  --version v0 >/dev/null

kubectl wait --for=condition=available deployment/vllm-llama3-8b-instruct --timeout=240s >/dev/null
kubectl wait --for=condition=available deployment/vllm-llama3-8b-instruct-epp --timeout=240s >/dev/null
kubectl wait --for=condition=available deployment/body-based-router --timeout=240s >/dev/null
kubectl wait --for=condition=available deployment/inference-gateway-istio --timeout=240s >/dev/null

NODE_PORT=$(kubectl get svc inference-gateway-istio -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME}-control-plane")
URL="http://${NODE_IP}:${NODE_PORT}/v1/chat/completions"

# Validate both ext-proc clusters exist in config dump.
kubectl exec deploy/inference-gateway-istio -c istio-proxy -- curl -s http://localhost:15000/config_dump > "${REPORT_DIR}/config_dump.json"

# Baseline short request (without explicit route header) to expose BBR behavior.
BASE_PAYLOAD='{"model":"food-review-1","messages":[{"role":"user","content":"hello"}],"max_tokens":5}'
BASE_CODE=$(curl -sS -m 20 -o "${REPORT_DIR}/baseline.out" -w "%{http_code}" -H 'Content-Type: application/json' -d "${BASE_PAYLOAD}" "${URL}" || true)

# Main repro load: long-body + streaming + explicit routing header to ensure requests hit EPP.
RESULTS="${REPORT_DIR}/stream_results.tsv"
FAILS="${REPORT_DIR}/stream_failures.log"
: > "${RESULTS}"
: > "${FAILS}"
for i in $(seq 1 300); do
  prompt=$(head -c 12000 /dev/zero | tr '\0' 'x')
  payload=$(jq -nc --arg p "$prompt" '{model:"food-review-1",messages:[{role:"user",content:$p}],max_tokens:256,temperature:0,stream:true}' )
  code=$(curl -sS -m 40 -o "${REPORT_DIR}/resp.txt" -w "%{http_code}" \
    -H 'Content-Type: application/json' \
    -H 'X-Gateway-Base-Model-Name: meta-llama/Llama-3.1-8B-Instruct' \
    -d "$payload" "$URL" || echo "CURLERR")
  size=$(wc -c <"${REPORT_DIR}/resp.txt" 2>/dev/null || echo 0)
  done_marker=0
  grep -q "data: \[DONE\]" "${REPORT_DIR}/resp.txt" 2>/dev/null && done_marker=1 || true
  echo -e "${i}\t${code}\t${size}\t${done_marker}" >> "${RESULTS}"
  if [[ "${code}" != "200" || "${done_marker}" != "1" ]]; then
    echo "----- req ${i} code=${code} size=${size} done=${done_marker}" >> "${FAILS}"
    head -n 40 "${REPORT_DIR}/resp.txt" >> "${FAILS}" || true
    echo >> "${FAILS}"
  fi
  sleep 0.02
done

SUMMARY=$(awk -F'\t' 'BEGIN{ok=0;bad=0;nodone=0} {if($2=="200" && $4==1) ok++; else bad++; if($4!=1) nodone++} END{printf("ok=%d bad=%d missing_done=%d total=%d",ok,bad,nodone,NR)}' "${RESULTS}")

{
  echo "istio_version=${ISTIO_VERSION}"
  echo "cluster_name=${CLUSTER_NAME}"
  echo "gateway_url=${URL}"
  echo "baseline_no_header_http_code=${BASE_CODE}"
  echo "${SUMMARY}"
  echo "config_dump_extproc_refs=$(grep -c 'envoy.filters.http.ext_proc' "${REPORT_DIR}/config_dump.json")"
} | tee "${REPORT_DIR}/summary.txt"

kubectl logs deploy/inference-gateway-istio -c istio-proxy --tail=200 > "${REPORT_DIR}/gateway-proxy.log" || true
kubectl logs deploy/vllm-llama3-8b-instruct-epp --tail=200 > "${REPORT_DIR}/epp.log" || true
kubectl logs deploy/body-based-router --tail=200 > "${REPORT_DIR}/bbr.log" || true

# Persist report outside trap cleanup scope in the current repository.
DEST_DIR="$(pwd)/$(basename "${REPORT_DIR}")"
cp -r "${REPORT_DIR}" "${DEST_DIR}"

echo "report_path=${DEST_DIR}"
