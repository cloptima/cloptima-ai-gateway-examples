#!/usr/bin/env bash
# Guardrail cost-governance: guardrailCostMode, guardrailMaxCostPerRequestCents,
# and guardrailCostExceededAction govern the cost of an optional heavier
# provider-backed guardrail scan (guardrailProviderIntegration: webhook /
# azure_content_safety / bedrock_guardrails) - downgrading to a lightweight
# profile, requiring approval, or blocking when that scan would cost too much.
# This example uses only the built-in pii/secret detectors, which run locally
# at zero cost, so it demonstrates the cost-tuning fields being accepted
# (requires the Enterprise guardrails plan) rather than the downgrade itself
# firing - see guardrail-detector-categories.sh for configuring a
# provider-backed scan.
# Run standalone: ./guardrail-cost-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum. No provider-backed scan is configured
# below, so this cap is never actually exercised - it only shows the field
# being accepted.
MAX_COST_PER_REQUEST_CENTS=1
SUFFIX="$(run_suffix)"
APP_ID="guardrail-cost-governance-$SUFFIX"

# 1. Cloptima setup - the policy, key, and binding are the whole contract.
echo "Creating a policy with guardrailCostMode='enforce', a \$$MAX_COST_PER_REQUEST_CENTS-cent cap, and guardrailCostExceededAction='downgrade'..."
POLICY_ERROR_FILE="$(mktemp)"
set +e
POLICY=$(create_policy "$(jq -n --arg name "guardrail-cost-governance-$SUFFIX" --arg model "$MODEL_DEFAULT" --argjson maxCostCents "$MAX_COST_PER_REQUEST_CENTS" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    guardrailDetectorsEnabled: ["pii", "secret"], guardrailOutputAction: "redact",
    guardrailCostMode: "enforce", guardrailMaxCostPerRequestCents: $maxCostCents,
    guardrailRequiredRiskTier: "low", guardrailCostExceededAction: "downgrade",
    guardrailLightweightProfileEnabled: true}')" 2>"$POLICY_ERROR_FILE")
POLICY_STATUS=$?
set -e
if [ "$POLICY_STATUS" -ne 0 ]; then
  echo "  denied: $(cat "$POLICY_ERROR_FILE")"
  echo "Expected (non-Enterprise plan): guardrail cost-tuning fields require the Enterprise guardrails plan. Nothing further to demonstrate without it."
  rm -f "$POLICY_ERROR_FILE"
  exit 0
fi
rm -f "$POLICY_ERROR_FILE"
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-guardrail-cost-governance-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Making a call under this policy..."
echo ""

# 2. Your application code.
call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "In one sentence, confirm this call ran under a guardrail cost-governance policy." \
  "cost-governance-probe"
jq '.' "$RESP_BODY_FILE"

# 3. What the gateway did. The cost cap only applies to a provider-backed
# scan; pii/secret detectors are local and free, so the call is served
# normally either way.
confirm_allowed "served under a guardrail cost-governance policy"

echo ""
echo "Confirmed: served - guardrailMaxCostPerRequestCents=$MAX_COST_PER_REQUEST_CENTS was accepted by the policy."
echo "With only local pii/secret detectors enabled, there's no provider-backed scan cost to cap here; add a"
echo "guardrailProviderIntegration (see guardrail-detector-categories.sh) to see the downgrade/require_approval/block"
echo "action trigger."
echo "Evidence: Policies tab ($CONSOLE_POLICIES) shows the saved guardrailCostMode/guardrailMaxCostPerRequestCents/guardrailCostExceededAction config."
