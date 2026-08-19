#!/usr/bin/env bash
# Same idea as quickstart-openai.sh, using the Anthropic-compatible /v1/messages
# shape instead - proves both API shapes work against the same gateway.
# Run standalone: ./quickstart-anthropic.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"
APP_ID="quickstart-anthropic-$SUFFIX"

# 1. Cloptima setup - the policy, key, and binding are the whole contract.
echo "Creating policy allowing $MODEL_DEFAULT on the managed Vertex AI provider..."
POLICY=$(create_policy "$(jq -n --arg name "quickstart-anthropic-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model]}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
echo "  policy $(echo "$POLICY" | jq -r '.name') -> $POLICY_ID"

echo "Minting a virtual key scoped to this policy..."
KEY=$(create_virtual_key "$(jq -n --arg name "vk-quickstart-anthropic-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Quickstart", appId: $appId, environment: "dev"}')")
KEY_ID=$(echo "$KEY" | jq -r '.id')
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
echo "  key $KEY_ID"

create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Quickstart", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Bound. Calling the gateway..."

# 2. Your application code.
call_messages "$ACCESS_TOKEN" "$MODEL_DEFAULT" \
  "In one sentence, confirm this call went through Cloptima's managed AI gateway." \
  "quickstart-anthropic"

# 3. What the gateway did.
jq '.' "$RESP_BODY_FILE"
confirm_allowed "quickstart call through a bound virtual key"

echo ""
echo "Evidence: Explorer tab ($CONSOLE_SPEND) - find this request_id to see attributed spend and usage."
