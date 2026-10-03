#!/usr/bin/env bash
# Quickstart: call the Cloptima AI Gateway with plain curl in the Anthropic-compatible
# /v1/messages shape. Send the Cloptima virtual key in x-api-key and use the gateway URL.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./quickstart-anthropic.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== Cloptima AI Gateway: Anthropic-compatible Quickstart ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally
# create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
# points at a key whose policy already matches.
get_access "quickstart-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "quickstart-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model]}')"

# Application code: a standard Messages API request.
echo "--- 1. Standard Messages API Request ---"
curl -sS -X POST "$BASE_URL/v1/messages" \
  -H "x-api-key: $ACCESS_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d @- <<JSON | jq -r '"Assistant: \(.content[0].text)\nTokens: \(.usage.input_tokens) input, \(.usage.output_tokens) output\nRequest ID: \(.id)"'
{
  "model": "$MODEL_DEFAULT",
  "max_tokens": 300,
  "messages": [{"role": "user", "content": "What are the main benefits of centralized LLM gateway governance?"}]
}
JSON

echo ""
echo "--- 2. Streaming Messages Request ---"
printf 'Assistant: '
curl -sS -N -X POST "$BASE_URL/v1/messages" \
  -H "x-api-key: $ACCESS_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d @- <<JSON | while IFS= read -r line; do
{
  "model": "$MODEL_DEFAULT",
  "max_tokens": 100,
  "messages": [{"role": "user", "content": "List 3 cloud cost best practices briefly."}],
  "stream": true
}
JSON
  case "$line" in
    data:*) printf '%s' "$(jq -r 'select(.type == "content_block_delta") | .delta.text // empty' <<<"${line#data: }")" ;;
  esac
done
echo ""

echo ""
echo "View live spend, latency, and attribution in the console: $CONSOLE_SPEND"
