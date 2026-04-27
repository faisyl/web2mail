#!/bin/bash

# Test script for ForwardEmail webhook with HMAC signature verification
# This script tests the webhook endpoint locally

set -e

echo "=== ForwardEmail Webhook Test Script ==="
echo ""

# Check if binary exists
if [ ! -f "web2mail" ]; then
    echo "❌ Binary not found. Building..."
    go build -o web2mail .
    echo "✅ Build complete"
fi

# Find the binary
BINARY="web2mail"

echo "Using binary: $BINARY"
echo ""

# Start server in background
echo "Starting webhook server..."
PORT=8080 \
DOMAIN=localhost \
PATH_URL=/ \
WEBHOOK_KEY=test-secret \
SENDMAIL_PATH="$(pwd)/mock-sendmail.sh" \
./$BINARY &

SERVER_PID=$!
echo "Server started with PID: $SERVER_PID"

# Wait for server to start
sleep 2

# Function to compute HMAC signature
compute_signature() {
    local payload_file=$1
    local secret=$2
    echo -n "$(cat "$payload_file" | openssl dgst -sha256 -hmac "$secret" | awk '{print $2}')"
}

# Test health endpoint
echo ""
echo "=== Testing health endpoint ==="
curl -s http://localhost:8080/health | jq . || echo "Failed to parse JSON"

# Test webhook endpoint with simple payload
echo ""
echo "=== Testing webhook endpoint (simple) ==="
SIGNATURE=$(compute_signature "test_payload.json" "test-secret")
echo "Computed signature: $SIGNATURE"
curl -s -X POST http://localhost:8080/webhook/email \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIGNATURE" \
  --data-binary @test_payload.json | jq . || echo "Failed"

# Test webhook endpoint with attachment
echo ""
echo "=== Testing webhook endpoint (with attachment) ==="
SIGNATURE=$(compute_signature "test_payload_with_attachment.json" "test-secret")
echo "Computed signature: $SIGNATURE"
curl -s -X POST http://localhost:8080/webhook/email \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIGNATURE" \
  --data-binary @test_payload_with_attachment.json | jq . || echo "Failed"

# Test authentication failure (wrong signature)
echo ""
echo "=== Testing authentication failure (wrong signature) ==="
curl -s -X POST http://localhost:8080/webhook/email \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: invalid-signature-12345" \
  --data-binary @test_payload.json || echo "Expected failure"

# Test missing signature
echo ""
echo "=== Testing missing signature ==="
curl -s -X POST http://localhost:8080/webhook/email \
  -H "Content-Type: application/json" \
  -d @test_payload.json || echo "Expected failure"

# === Multi-domain tests ===
echo ""
echo "=== Testing multi-domain routing ==="

PORT=8082 \
DOMAIN=legacy.test \
WEBHOOK_KEY=legacy-secret \
DOMAIN_1=alpha.test \
WEBHOOK_KEY_1=alpha-secret \
DOMAIN_2=beta.test \
WEBHOOK_KEY_2=beta-secret \
SENDMAIL_PATH="$(pwd)/mock-sendmail.sh" \
./$BINARY &

MULTI_PID=$!
sleep 1

# Test 1: alpha.test with correct key -> 200
echo ""
echo "--- alpha.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "alpha-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: alpha.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 2: beta.test with correct key -> 200
echo ""
echo "--- beta.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "beta-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: beta.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 3: alpha.test with wrong key -> 401
echo ""
echo "--- alpha.test wrong key (expect 401) ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: alpha.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: wrong-sig" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 4: unknown host -> 403
echo ""
echo "--- unknown host (expect 403) ---"
SIG=$(compute_signature "test_payload.json" "alpha-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: unknown.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

# Test 5: legacy domain still works -> 200
echo ""
echo "--- legacy.test correct key (expect 200) ---"
SIG=$(compute_signature "test_payload.json" "legacy-secret")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8082/webhook/email \
  -H "Host: legacy.test" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  --data-binary @test_payload.json)
echo "Status: $STATUS"

kill $MULTI_PID
wait $MULTI_PID 2>/dev/null || true

# Cleanup
echo ""
echo "=== Cleaning up ==="
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo ""
echo "✅ Tests complete!"
