#!/usr/bin/env bash
# Adaptive routing in observe mode. The policy lists candidate models per cost/latency tier under
# metadata.routing.adaptive. In observe mode the router logs which candidate it would have picked
# for each call without changing where traffic goes, so every call is served exactly as requested.
# Moving to canary or enforce additionally needs an approved eval and release gate
# (see prompt-release-workflow.sh), so only observe mode is shown here.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./adaptive-routing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_CHEAP="vertex_ai/gemini-3.5-flash-lite"
MODEL_BALANCED="vertex_ai/gemini-3.5-flash-lite"
MODEL_STRONG="vertex_ai/gemini-3.8-flash"

echo "=== Adaptive Routing: Cost & Performance Optimization ==="
echo ""

# Governance setup: a policy with candidate model tiers for adaptive routing in observe mode.
# Platform admins normally create it once in the Console, Terraform, or CI. Skipped when
# CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
get_access "adaptive-routing-demo" "$(jq -n --arg cheap "$MODEL_CHEAP" --arg balanced "$MODEL_BALANCED" --arg strong "$MODEL_STRONG" '{
  name: "adaptive-routing-policy", mode: "enforce", budgetMode: "hard",
  allowedProviders: ["vertex_ai"], allowedModels: ([$cheap, $balanced, $strong] | unique),
  metadata: {routing: {adaptive: {
    mode: "observe", route_risk_ceiling: "low", candidate_set_version: "v1",
    candidate_models: {cheap: [$cheap], balanced: [$balanced], strong: [$strong]}}}}}')"

# Application code: requests name the model they want, as usual.
TASKS=(
  "Extract city and temperature from: \"It is 22C in London today\"."
  "Summarize the CAP theorem and its impact on distributed consensus in 2 sentences."
)
for i in "${!TASKS[@]}"; do
  echo "[Request $((i + 1))] ${TASKS[$i]}"
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_BALANCED" --arg prompt "${TASKS[$i]}" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
  if [ "$HTTP_CODE" = "200" ]; then
    jq -r '"Assistant: \(.choices[0].message.content)\nUsage: \(.usage.total_tokens) tokens | Request ID: \(.id)"' "$RESP_BODY_FILE"
  else
    echo "Request failed (HTTP $HTTP_CODE):"; describe_block
  fi
  echo ""
done

echo "The routing decision log is a console-side evidence trail:"
echo "  - Recommendations & Routing: $CONSOLE_RECOMMENDATIONS"
echo "  - Audit (per-call decisions): $CONSOLE_AUDIT"
echo "  - Policies (candidate tiers): $CONSOLE_POLICIES"
