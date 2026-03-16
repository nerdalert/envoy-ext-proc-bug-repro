# Istio 1.28.1 Ext-Proc Chain Bug Trigger (Reproduced)

Date: 2026-03-16

This reproduces the Envoy ext-proc chain bug on an Envoy binary from Istio `proxyv2:1.28.1`.

## What this reproduces

Two chained `envoy.filters.http.ext_proc` filters:
1. ext-proc-1: response headers only
2. ext-proc-2: `response_body_mode: FULL_DUPLEX_STREAMED`

Under concurrent 50KB POST traffic, responses are intermittently truncated (HTTP `200` with short body), and ext-proc server logs show:
- `send error rpc error: code = Canceled desc = context canceled`

This matches the failure signature in `envoyproxy/envoy#41654`.

## Repro assets in this repo

- Ext-proc server: `repro-extproc/extproc/main.go`
- Echo backend: `repro-extproc/echo/main.go`
- K8s manifests: `repro-extproc/manifests/repro.yaml`

## Prerequisites

- `kind`, `kubectl`, `docker`, `curl`, `jq`, `xargs`
- A kind cluster (commands below use `igw-repro-1281`)

## Deploy repro stack

```bash
kind create cluster --name igw-repro-1281 --image kindest/node:v1.30.13
kubectl config use-context kind-igw-repro-1281

cd repro-extproc/extproc && docker build -t extproc-repro:latest .
cd ../echo && docker build -t echo-repro:latest .

kind load docker-image extproc-repro:latest --name igw-repro-1281
kind load docker-image echo-repro:latest --name igw-repro-1281

cp repro-extproc/manifests/repro.yaml /tmp/repro-1281.yaml
sed -i 's/extproc-repro/extproc-repro-1281/g' /tmp/repro-1281.yaml
kubectl apply -f /tmp/repro-1281.yaml

kubectl -n extproc-repro-1281 set image deploy/extproc extproc=extproc-repro:latest
kubectl -n extproc-repro-1281 set image deploy/echo echo=echo-repro:latest
kubectl -n extproc-repro-1281 patch deploy extproc --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
kubectl -n extproc-repro-1281 patch deploy echo --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

kubectl -n extproc-repro-1281 rollout restart deploy/extproc deploy/echo
kubectl -n extproc-repro-1281 rollout status deploy/extproc --timeout=180s
kubectl -n extproc-repro-1281 rollout status deploy/echo --timeout=180s
kubectl -n extproc-repro-1281 rollout status deploy/envoy --timeout=180s
```

## Trigger traffic

```bash
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' igw-repro-1281-control-plane)
PORT=$(kubectl -n extproc-repro-1281 get svc envoy -o jsonpath='{.spec.ports[0].nodePort}')
URL="http://${NODE_IP}:${PORT}/"

WORK=/tmp/extproc-bug-1281
rm -rf "$WORK" && mkdir -p "$WORK"
dd if=/dev/urandom of="$WORK/50k.dat" bs=1k count=50 status=none
EXPECTED=$(wc -c < "$WORK/50k.dat")

cat > "$WORK/run_one.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
idx="$1"; url="$2"; file="$3"; expected="$4"
out="/tmp/extproc-bug-1281/resp-${idx}.bin"
code=$(curl -sS -m 25 -o "$out" -w "%{http_code}" --data-binary "@$file" "$url" || echo CURLERR)
size=$(wc -c < "$out" 2>/dev/null || echo 0)
trunc=0
if [[ "$code" == "200" ]] && (( size < expected )); then trunc=1; fi
printf "%s\t%s\t%s\t%s\n" "$idx" "$code" "$size" "$trunc"
EOS
chmod +x "$WORK/run_one.sh"

seq 1 100 | xargs -I{} -P 20 bash "$WORK/run_one.sh" {} "$URL" "$WORK/50k.dat" "$EXPECTED" > "$WORK/results.tsv"
awk -F'\t' 'BEGIN{ok=0;bad=0;tr=0} {if($2=="200") ok++; else bad++; if($4==1) tr++} END{printf("http200=%d bad=%d truncated=%d total=%d\n",ok,bad,tr,NR)}' "$WORK/results.tsv"
awk -F'\t' '$4==1{print}' "$WORK/results.tsv" | head -n 20
```

## Observed result in this repo run

- Summary: `http200=100 bad=0 truncated=36 total=100`
- Artifacts:
  - `reports/1.28.1/summary.txt`
  - `reports/1.28.1/results.tsv`
  - `reports/1.28.1/extproc.log`
  - `reports/1.28.1/envoy.log`

## Log confirmation

```bash
kubectl -n extproc-repro-1281 logs deploy/extproc --tail=200 | grep -E "send error|context canceled"
```

Expected failure signature:

```text
send error rpc error: code = Canceled desc = context canceled
```
