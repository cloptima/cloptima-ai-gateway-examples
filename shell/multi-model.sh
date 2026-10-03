#!/usr/bin/env bash
# One policy allowlisting two Vertex AI Gemini models. The application calls each model through
# the same virtual key and compares latency and token usage.
#
# A model can fail for two reasons: the policy does not allow it (403), or it is allowed but
# has no pricing entry yet so a spend-limited path fails closed. The script prints the gateway's
# reason for any failure.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./multi-model.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODELS=(
  "vertex_ai/gemini-3.5-flash-lite"
  "vertex_ai/gemini-3.8-flash"
)

echo "=== Multi-Model Gateway: Unified Model Comparison ==="
echo ""

# Governance setup: one policy allowlisting both models. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "multi-model-demo" "$(jq -n --argjson models "$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -s .)" '{
  name: "multi-model-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: $models}')"

# Application code: the same request against each model.
PROMPT="Explain the difference between vertical and horizontal autoscaling in 2 sentences."
echo "Evaluating prompt across ${#MODELS[@]} models: \"$PROMPT\""
echo ""
for model in "${MODELS[@]}"; do
  echo "--- Model: $model ---"
  read -r HTTP_CODE TIME_TOTAL < <(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code} %{time_total}\n' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$model" --arg prompt "$PROMPT" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
  if [ "$HTTP_CODE" = "200" ]; then
    jq -r --arg t "$TIME_TOTAL" '"Assistant: \(.choices[0].message.content)\nMetrics: \($t)s latency | \(.usage.total_tokens) tokens (\(.usage.prompt_tokens) in / \(.usage.completion_tokens) out)"' "$RESP_BODY_FILE"
  else
    echo "Error calling $model (HTTP $HTTP_CODE):"
    describe_block
  fi
  echo ""
done

echo "Compare aggregate cost and latency per model in the Cloptima Console:"
echo "  - Explorer: $CONSOLE_SPEND"
echo "  - Recommendations: $CONSOLE_RECOMMENDATIONS"
