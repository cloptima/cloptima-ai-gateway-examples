#!/usr/bin/env bash
# Summarization service under an output-token cap. A request within the cap is served. A request
# asking for more output than the policy allows is rejected pre-flight, before any compute cost.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./token-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
# Illustrative, not a platform minimum. The minimum allowed value is 64.
MAX_OUTPUT_TOKENS=200

echo "=== Summarization Service: Output Token Boundaries ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "token-limit-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson tokens "$MAX_OUTPUT_TOKENS" '{
  name: "token-limit-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model], maxOutputTokens: $tokens}')"

# Application code: the same call with two different max_tokens values.
summarize() {
  local prompt="$1" max_tokens="$2"
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$prompt" --argjson max "$max_tokens" \
      '{model: $model, max_tokens: $max, messages: [{role: "user", content: $prompt}]}')")
}

echo "--- Case 1: Concise Summary (within the $MAX_OUTPUT_TOKENS token cap) ---"
summarize "Summarize the concept of API gateways in 10 words." 30
if [ "$HTTP_CODE" = "200" ]; then
  jq -r '"Assistant: \(.choices[0].message.content)\nTokens used: \(.usage.completion_tokens)"' "$RESP_BODY_FILE"
else
  echo "Unexpected error (HTTP $HTTP_CODE):"; describe_block
fi

echo ""
echo "--- Case 2: Oversized Generation (500 tokens exceeds the $MAX_OUTPUT_TOKENS token cap) ---"
summarize "Write a comprehensive 500-word analysis on distributed microservice architectures." 500
if [ "$HTTP_CODE" = "403" ]; then
  echo "Gateway token boundary enforced (HTTP 403):"
  describe_block
  echo ""
  echo "Application fallback: request rejected pre-flight before incurring compute costs."
  echo "Notice to client: \"Please request a concise summary (under $MAX_OUTPUT_TOKENS tokens) or adjust your policy quota.\""
else
  echo "Processed unexpectedly (HTTP $HTTP_CODE)."
fi

echo ""
echo "Review blocked requests and policy limits in the Cloptima Console:"
echo "  - Audit Trail: $CONSOLE_AUDIT"
echo "  - Policies: $CONSOLE_POLICIES"
