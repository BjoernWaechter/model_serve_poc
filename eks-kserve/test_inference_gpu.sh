#!/usr/bin/env bash
set -euo pipefail

INGRESS_HOST=$(terraform -chdir="$(dirname "$0")/iac" output -raw ingress_hostname)
SERVICE_NAME="phi3-chat"
NAMESPACE="kserve-test"
HOST_HEADER="${SERVICE_NAME}.${NAMESPACE}.${INGRESS_HOST}"

echo "=== KServe GPU inference test (Phi-3-mini via vLLM) ==="
echo "Ingress:  ${INGRESS_HOST}"
echo "Service:  ${SERVICE_NAME}.${NAMESPACE}"
echo "Host:     ${HOST_HEADER}"
echo ""

echo "--- Sending chat request (may take up to 5 min on cold start) ---"
HTTP_CODE=$(curl -s -o /tmp/kserve_gpu_response.json -w "%{http_code}" --max-time 600 \
  -H "Host: ${HOST_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"model":"model","messages":[{"role":"user","content":"Explain Kubernetes in one sentence"}],"max_tokens":100}' \
  "http://${INGRESS_HOST}/v1/chat/completions" || true)

BODY=$(cat /tmp/kserve_gpu_response.json 2>/dev/null | jq || echo "")

echo "HTTP ${HTTP_CODE}"
echo "Response: ${BODY}"
echo ""

rm -f /tmp/kserve_gpu_response.json

if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"choices"'; then
  echo "PASS"
else
  echo "FAIL"
  exit 1
fi
