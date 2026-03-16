# Istio 1.29.1 Ext-Proc Chain Bug Trigger (Same Harness)

Date: 2026-03-16

This runs the same minimal Envoy + ext-proc + echo harness as the 1.28.1 report, but with Envoy image `proxyv2:1.29.1`.

## Goal

Validate whether the same two-ext-proc chain reproducer still shows truncation:
1. ext-proc-1: response headers only
2. ext-proc-2: `response_body_mode: FULL_DUPLEX_STREAMED`

## Prerequisites

- `kind`, `kubectl`, `docker`, `curl`, `jq`, `xargs`
- A kind cluster (commands below use `igw-repro-1291`)

## Deploy repro stack (1.29.1 image)

```bash
kind create cluster --name igw-repro-1291 --image kindest/node:v1.30.13
kubectl config use-context kind-igw-repro-1291

cd repro-extproc/extproc && docker build -t extproc-repro:latest .
cd ../echo && docker build -t echo-repro:latest .

kind load docker-image extproc-repro:latest --name igw-repro-1291
kind load docker-image echo-repro:latest --name igw-repro-1291

cp repro-extproc/manifests/repro.yaml /tmp/repro-1291.yaml
sed -i 's/extproc-repro/extproc-repro-1291/g' /tmp/repro-1291.yaml
sed -i 's/docker.io\/istio\/proxyv2:1.28.1/docker.io\/istio\/proxyv2:1.29.1/g' /tmp/repro-1291.yaml
kubectl apply -f /tmp/repro-1291.yaml

kubectl -n extproc-repro-1291 set image deploy/extproc extproc=extproc-repro:latest
kubectl -n extproc-repro-1291 set image deploy/echo echo=echo-repro:latest
kubectl -n extproc-repro-1291 patch deploy extproc --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
kubectl -n extproc-repro-1291 patch deploy echo --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'

kubectl -n extproc-repro-1291 rollout restart deploy/extproc deploy/echo
kubectl -n extproc-repro-1291 rollout status deploy/extproc --timeout=180s
kubectl -n extproc-repro-1291 rollout status deploy/echo --timeout=180s
kubectl -n extproc-repro-1291 rollout status deploy/envoy --timeout=180s
```

## Trigger traffic

Use the exact same load pattern as 1.28.1, changing namespace/control-plane name:

```bash
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' igw-repro-1291-control-plane)
PORT=$(kubectl -n extproc-repro-1291 get svc envoy -o jsonpath='{.spec.ports[0].nodePort}')
URL="http://${NODE_IP}:${PORT}/"

WORK=/tmp/extproc-bug-1291
rm -rf "$WORK" && mkdir -p "$WORK"
dd if=/dev/urandom of="$WORK/50k.dat" bs=1k count=50 status=none
EXPECTED=$(wc -c < "$WORK/50k.dat")

cat > "$WORK/run_one.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
idx="$1"; url="$2"; file="$3"; expected="$4"
out="/tmp/extproc-bug-1291/resp-${idx}.bin"
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

- Summary: `http200=100 bad=0 truncated=34 total=100`
- Artifacts:
  - `reports/1.29.1/summary.txt`
  - `reports/1.29.1/results.tsv`
  - `reports/1.29.1/extproc.log`
  - `reports/1.29.1/envoy.log`

## Log confirmation

```bash
kubectl -n extproc-repro-1291 logs deploy/extproc --tail=200 | grep -E "send error|context canceled"
```

Observed signature includes:

```text
send error rpc error: code = Canceled desc = context canceled
```
