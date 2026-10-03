#!/usr/bin/env bash
# Set a per-request scan cost cap in a provider-backed guardrail profile.
# The billable managed scan requires available Cloptima managed credits.
# Run standalone: ./guardrail-cost-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
MAX_COST_PER_REQUEST_CENTS=1
SUFFIX="$(run_suffix)"
APP_ID="guardrail-cost-governance-$SUFFIX"
echo "Prerequisite: the account must have managed credits available for this billable guardrail scan."
PROFILE=$(create_guardrail_profile "$(jq -n --arg name "guardrail-cost-governance-$SUFFIX" --argjson maxCostCents "$MAX_COST_PER_REQUEST_CENTS" \
  '{name: $name, description: "Managed Model Armor scan with a per-request cost cap", definition: {
    input: {action: "observe", detectors: {secret: {}}}, output: {action: "observe", detectors: {secret: {}}},
    provider_integration: {kind: "google_model_armor", credential_source: "cloptima_managed", scan_directions: "input"},
    cost: {mode: "enforce", max_cost_per_request_cents: $maxCostCents, exceeded_action: "block"}}}')")
PROFILE_ID=$(echo "$PROFILE" | jq -r '.id')
POLICY=$(create_policy "$(jq -n --arg name "guardrail-cost-governance-$SUFFIX" --arg model "$MODEL_DEFAULT" --arg profileId "$PROFILE_ID" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", failMode: "fail_closed", allowedProviders: ["vertex_ai"], allowedModels: [$model], guardrailProfileId: $profileId}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
KEY=$(create_virtual_key "$(jq -n --arg name "vk-guardrail-cost-governance-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null

call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "Reply with exactly: scan cost is within the configured cap." "cost-governance-probe"
confirm_allowed "provider scan stayed within the configured cost cap"
echo "Confirmed: the profile's $MAX_COST_PER_REQUEST_CENTS-cent cap admitted this scan."
echo "Profile: $PROFILE_ID; policy: $POLICY_ID; review them in $CONSOLE_POLICIES and $CONSOLE_AUDIT"
