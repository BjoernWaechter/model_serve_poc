#!/usr/bin/env bash
set -euo pipefail

URL=$(terraform -chdir="$(dirname "$0")/iac" output -raw iris_url)

echo "=== KServe inference test (sklearn iris) ==="
echo "URL: ${URL}"
echo ""

echo "--- Sending prediction request (may take up to 120s on cold start) ---"
HTTP_CODE=$(curl -s -o /tmp/kserve_response.json -w "%{http_code}" --max-time 120 \
  -H "Content-Type: application/json" \
  -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}' \
  "${URL}" || true)

BODY=$(cat /tmp/kserve_response.json 2>/dev/null || echo "")

echo "HTTP ${HTTP_CODE}"
echo "Response: ${BODY}"
echo ""

rm -f /tmp/kserve_response.json

if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"predictions"'; then
  echo "PASS"
else
  echo "FAIL"
  exit 1
fi
