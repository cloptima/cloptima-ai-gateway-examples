#!/usr/bin/env bash
# Use a profile custom rule to block a fictional SSN format.
# Run standalone: ./pii-guardrail.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
SUFFIX="$(run_suffix)"
APP_ID="pii-guardrail-$SUFFIX"
PROFILE=$(create_guardrail_profile "$(jq -n --arg name "pii-guardrail-$SUFFIX" \
  '{name: $name, description: "Block credentials and configured personal-data formats", definition: {
    input: {action: "block", detectors: {secret: {}}, custom_rules: [{id: "us_ssn", match: {regex: "\\b\\d{3}-\\d{2}-\\d{4}\\b"}}]},
    output: {action: "observe", detectors: {secret: {}}}}}')")
PROFILE_ID=$(echo "$PROFILE" | jq -r '.id')
POLICY=$(create_policy "$(jq -n --arg name "pii-guardrail-$SUFFIX" --arg model "$MODEL_DEFAULT" --arg profileId "$PROFILE_ID" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", failMode: "fail_closed", allowedProviders: ["vertex_ai"], allowedModels: [$model], guardrailProfileId: $profileId}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
KEY=$(create_virtual_key "$(jq -n --arg name "vk-pii-guardrail-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null

call_chat "$(echo "$KEY" | jq -r '.accessToken')" "$MODEL_DEFAULT" \
  "This fictional QA record contains SSN 123-45-6789. Summarize it." "pii-format-rule-probe"
confirm_blocked "profile custom rule for a US SSN" 403
echo "Confirmed: the profile rule blocked the matching input before model egress."
echo "Profile: $PROFILE_ID; policy: $POLICY_ID; review them in $CONSOLE_POLICIES and $CONSOLE_AUDIT"
