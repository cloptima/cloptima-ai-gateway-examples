#!/usr/bin/env bash
# Guardrail cost-governance: guardrailCostMode governs whether the gateway
# will run a heavier (and costlier) provider-backed detector scan per
# request, and guardrailCostExceededAction decides what happens when that
# scan's cost would exceed guardrailMaxCostPerRequestCents. Deliberately pins
# a tiny cost cap (mirrors budget-limit.sh's "pin a small threshold to keep
# the knob meaningful" pattern) so cost-exceeded behavior triggers
# deterministically, then enables guardrailLightweightProfileEnabled so
# 'downgrade' has a cheaper profile to fall back to instead of failing
# closed. All cost-tuning fields are Enterprise-gated
# (llm_guardrail_enterprise), so the policy create is allowed to fail (set +e
# around it) to show that gate too on a non-Enterprise customer.
# Run standalone: ./guardrail-cost-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum. Deliberately tiny so any heavier
# provider-backed scan exceeds it and the cost-exceeded action is exercised.
MAX_COST_PER_REQUEST_CENTS=1
SUFFIX="$(run_suffix)"
APP_ID="guardrail-cost-governance-$SUFFIX"

echo "Creating a policy with guardrailCostMode='enforce', a \$$MAX_COST_PER_REQUEST_CENTS-cent cap, and downgrade-to-lightweight on exceed..."
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
  echo "Expected (non-Enterprise customer): guardrail cost-tuning fields require the llm_guardrail_enterprise entitlement. Nothing further to demonstrate without it."
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
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Making a call that should trip the cost-exceeded downgrade..."
echo ""

call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "In one sentence, confirm this call ran under a guardrail cost-governance policy." \
  "cost-governance-probe" "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Expected: allowed - the $MAX_COST_PER_REQUEST_CENTS-cent cap is exceeded by the full detector scan, so the"
echo "request is served via the cheaper guardrailLightweightProfileEnabled fallback rather than blocked outright"
echo "(guardrailCostExceededAction: 'downgrade'). Re-run with guardrailCostExceededAction: 'block' to see the deny"
echo "path instead, or 'require_approval' to route it through the LLMGatewayApproval governance queue."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - the record shows the cost-exceeded downgrade decision; Dashboard tab ($CONSOLE_DASHBOARD) surfaces guardrailCostUsd/guardrailAvoidedCostUsd."
