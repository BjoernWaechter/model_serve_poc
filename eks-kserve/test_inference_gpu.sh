#!/usr/bin/env bash
set -euo pipefail

URL=$(terraform -chdir="$(dirname "$0")/iac" output -raw llm1_url)

echo "=== KServe GPU inference test (Phi-3-mini via vLLM) ==="
echo "URL: ${URL}"
echo ""

echo "--- Sending chat request (may take up to 5 min on cold start) ---"
HTTP_CODE=$(curl -s -o /tmp/kserve_gpu_response.json -w "%{http_code}" --max-time 600 \
  -H "Content-Type: application/json" \
  -d '{"model":"model","messages":[{"role":"user","content":"Explain a Hopper in NZ in 200 words"}],"max_tokens":100}' \
  "${URL}" || true)

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
