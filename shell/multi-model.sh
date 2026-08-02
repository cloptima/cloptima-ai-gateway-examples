#!/usr/bin/env bash
# One policy allowlisting several Vertex AI Gemini model variants (default
# flash, a cheaper flash-lite, and a higher-capability pro), mints a key,
# and calls each once - the "one policy, several models, compare cost and
# latency" story. These examples are built with Gemini models; bring your
# own credentials for other providers/models via the byok example.
#
# A model here can fail for two very different reasons:
#   - policy/model block (403)  -> the model isn't allowed by this policy
#   - missing pricing (402/403) -> the model is allowed, but the gateway's
#     pricing catalog doesn't have a cost entry for it yet, so a spend-
#     limited path fails closed. That's a pricing-catalog gap, not a sign
#     the model itself is unsupported - check the printed reason below.
# Run standalone: ./multi-model.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODELS=(
  "vertex_ai/gemini-2.5-flash"
  "vertex_ai/gemini-2.5-flash-lite"
  "vertex_ai/gemini-2.5-pro"
)
SUFFIX="$(run_suffix)"
APP_ID="multi-model-$SUFFIX"

echo "Creating policy allowlisting ${#MODELS[@]} Vertex AI Gemini model variants..."
MODELS_JSON=$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -s .)
POLICY=$(create_policy "$(jq -n --arg name "multi-model-$SUFFIX" --argjson models "$MODELS_JSON" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: $models}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
echo "  policy $(echo "$POLICY" | jq -r '.name') -> $POLICY_ID"

KEY=$(create_virtual_key "$(jq -n --arg name "vk-multi-model-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Calling each model once..."
echo ""

for model in "${MODELS[@]}"; do
  call_chat "$ACCESS_TOKEN" "$model" "In one short sentence, name the model you are." \
    "$model" "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev"
  jq -c '{status: (.error // .choices[0].message.content // .)}' "$RESP_BODY_FILE" 2>/dev/null || cat "$RESP_BODY_FILE"
done

echo ""
echo "If any model above came back blocked with a pricing-related reason rather than a policy/model-allow reason,"
echo "that means the model is real and allowlisted but the gateway pricing catalog needs a cost entry for it -"
echo "check the pricing catalog/overlay, not the policy."
echo ""
echo "Evidence: Explorer tab ($CONSOLE_SPEND) - filter by app \"$APP_ID\" to compare cost and latency across every model called above."
