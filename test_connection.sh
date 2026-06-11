#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://100.64.30.99:8000"

echo "[1/3] Start session heartbeat..."
curl -sS -X POST "${BASE_URL}/api/v1/heartbeat" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"test-e2e-001","status":"active"}'

echo
sleep 1

echo "[2/3] Send SOP log..."
curl -sS -X POST "${BASE_URL}/api/v1/sop-log" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"test-e2e-001","step_name":"network_validation","timestamp":"2026-03-02T12:00:00Z","image_base64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="}'

echo
sleep 1

echo "[3/3] Terminate session heartbeat..."
curl -sS -X POST "${BASE_URL}/api/v1/heartbeat" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"test-e2e-001","status":"terminated"}'

echo
echo "Done."
