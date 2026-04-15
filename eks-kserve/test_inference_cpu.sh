#!/usr/bin/env bash
set -euo pipefail

INGRESS_HOST=$(terraform -chdir="$(dirname "$0")/iac" output -raw ingress_hostname)
SERVICE_NAME="sklearn-iris"
NAMESPACE="kserve-test"
HOST_HEADER="${SERVICE_NAME}.${NAMESPACE}.${INGRESS_HOST}"

echo "=== KServe inference test ==="
echo "Ingress:  ${INGRESS_HOST}"
echo "Service:  ${SERVICE_NAME}.${NAMESPACE}"
echo "Host:     ${HOST_HEADER}"
echo ""

echo "--- Sending prediction request (may take up to 120s on cold start) ---"
HTTP_CODE=$(curl -s -o /tmp/kserve_response.json -w "%{http_code}" --max-time 120 \
  -H "Host: ${HOST_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}' \
  "http://${INGRESS_HOST}/v1/models/${SERVICE_NAME}:predict" || true)

BODY=$(cat /tmp/kserve_response.json 2>/dev/null || echo "")

echo "HTTP ${HTTP_CODE}"
echo "Response: ${BODY}"
echo ""

if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"predictions"'; then
  echo "PASS"
else
  echo "FAIL"
  exit 1
fi
