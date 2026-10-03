#!/usr/bin/env bash
# Quickstart: call the Cloptima AI Gateway with plain curl in the OpenAI-compatible shape.
# Integrating takes two changes to an existing OpenAI call: send a Cloptima virtual key
# as the bearer token and use the gateway URL.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./quickstart-openai.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== Cloptima AI Gateway: OpenAI-compatible Quickstart ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally
# create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
# points at a key whose policy already matches.
get_access "quickstart-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "quickstart-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model]}')"

# Application code: a standard chat completion. The gateway URL and a virtual key are the only
# Cloptima-specific parts. Send a User-Agent: the gateway sits behind a bot-managed edge.
echo "--- 1. Standard Chat Completion ---"
curl -sS -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d @- <<JSON | jq -r '"Assistant: \(.choices[0].message.content)\nTokens: \(.usage.total_tokens) (prompt: \(.usage.prompt_tokens), completion: \(.usage.completion_tokens))\nRequest ID: \(.id)"'
{
  "model": "$MODEL_DEFAULT",
  "messages": [
    {"role": "system", "content": "You are a helpful cloud engineer."},
    {"role": "user", "content": "Explain what an AI gateway does in one clear sentence."}
  ]
}
JSON

echo ""
echo "--- 2. Streaming Chat Completion ---"
printf 'Assistant: '
curl -sS -N -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d @- <<JSON | while IFS= read -r line; do
{
  "model": "$MODEL_DEFAULT",
  "messages": [{"role": "user", "content": "Count from 1 to 5 with commas."}],
  "stream": true
}
JSON
  case "$line" in
    "data: [DONE]" | "") ;;
    data:*) printf '%s' "$(jq -r '.choices[0].delta.content // empty' <<<"${line#data: }")" ;;
  esac
done
echo ""

echo ""
echo "View live spend, latency, and attribution in the console: $CONSOLE_SPEND"
