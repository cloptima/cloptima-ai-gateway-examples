#!/usr/bin/env bash
# Creates a policy with a realistic maxOutputTokens cap - well above the
# platform floor of 64 - and shows a long-response request get blocked
# pre-flight rather than silently truncated.
# Run standalone: ./token-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum - the platform floor is 64.
MAX_OUTPUT_TOKENS=200
SUFFIX="$(run_suffix)"
APP_ID="token-limit-$SUFFIX"

# 1. Cloptima setup - the policy, key, and binding are the whole contract.
echo "Creating policy with maxOutputTokens=$MAX_OUTPUT_TOKENS..."
POLICY=$(create_policy "$(jq -n --arg name "token-limit-$SUFFIX" --arg model "$MODEL_DEFAULT" --argjson tokens "$MAX_OUTPUT_TOKENS" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], maxOutputTokens: $tokens}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-token-limit-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Requesting a long response the policy should reject..."
echo ""

# 2. Your application code.
call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "Write a detailed 500-word essay about the history of cloud computing." \
  "token-limit-probe"
jq '.' "$RESP_BODY_FILE"

# 3. What the gateway did. confirm_blocked stops the script if the policy
# above was not held, so a silent regression cannot print as a success.
confirm_blocked "maxOutputTokens=$MAX_OUTPUT_TOKENS" 403 "output limit"

echo ""
echo "Confirmed: blocked pre-flight ($LAST_HTTP_CODE) - the request's default max_tokens exceeds $MAX_OUTPUT_TOKENS,"
echo "and the error names both the requested and the allowed value."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - the block record names both the requested and allowed token values; Policies tab ($CONSOLE_POLICIES) shows the maxOutputTokens config."
