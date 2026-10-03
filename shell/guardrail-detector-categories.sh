#!/usr/bin/env bash
# Creates an isolated policy-bound profile for each managed provider scan.
# Each scan is billable and requires available Cloptima managed credits.
# Run standalone: ./guardrail-detector-categories.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
SUFFIX="$(run_suffix)"

profile_input() {
  local name="$1" integration="$2"
  jq -n --arg name "$name" --argjson integration "$integration" \
    '{name: $name, description: "Managed provider scan validation example", definition: {
      input: {action: "observe", detectors: {secret: {}}},
      output: {action: "observe", detectors: {secret: {}}},
      provider_integration: $integration}}'
}

echo "Creating one fail-closed profile and policy per managed scan provider..."
echo "Prerequisite: the account must have managed credits available for billable guardrail scans."

run_provider() {
  local provider_id="$1" name="$2" integration="$3" retain="$4"
  local resource_name profile profile_id policy policy_id key key_id access_token binding binding_id
  resource_name="guardrail-$provider_id-$SUFFIX"
  profile=$(create_guardrail_profile "$(profile_input "$resource_name" "$integration")")
  profile_id=$(jq -r '.id' <<<"$profile")
  policy=$(create_policy "$(jq -n --arg name "$resource_name" --arg model "$MODEL_DEFAULT" --arg profileId "$profile_id" \
    '{name: $name, mode: "enforce", budgetMode: "hard_fast", failMode: "fail_closed", allowedProviders: ["vertex_ai"], allowedModels: [$model], guardrailProfileId: $profileId}')")
  policy_id=$(jq -r '.id' <<<"$policy")
  key=$(create_virtual_key "$(jq -n --arg name "vk-$resource_name" --arg appId "$resource_name" \
    '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
  key_id=$(jq -r '.id' <<<"$key")
  access_token=$(jq -r '.accessToken' <<<"$key")
  binding=$(create_binding "$(jq -n --arg policyId "$policy_id" --arg appId "$resource_name" \
    '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')")
  binding_id=$(jq -r '.id' <<<"$binding")
  call_chat "$access_token" "$MODEL_DEFAULT" "Reply with exactly: guardrail scan passed." "$name"
  if [ "$LAST_OUTCOME" != "allowed" ]; then
    echo "  reason: $(jq -r '.error.message // .error // .message // "No response detail"' "$RESP_BODY_FILE")"
    FAILURES+=("$name (HTTP $LAST_HTTP_CODE)")
  else
    if [ "$retain" = "true" ]; then
      echo "  retained for review - profile: $profile_id; policy: $policy_id; app: $resource_name"
    fi
  fi

  if [ "$retain" = "false" ]; then
    if ! graphql 'mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }' "$(jq -n --arg id "$binding_id" '{id: $id}')" >/dev/null 2>&1; then
      FAILURES+=("$name cleanup (binding)")
    fi
    if ! graphql 'mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }' "$(jq -n --arg id "$policy_id" '{id: $id}')" >/dev/null 2>&1; then
      FAILURES+=("$name cleanup (policy)")
    fi
    if ! graphql 'mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }' "$(jq -n --arg id "$profile_id" '{id: $id}')" >/dev/null 2>&1; then
      FAILURES+=("$name cleanup (profile)")
    fi
    if ! graphql 'mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }' "$(jq -n --arg id "$key_id" '{id: $id}')" >/dev/null 2>&1; then
      FAILURES+=("$name cleanup (key)")
    fi
  fi
}

FAILURES=()
run_provider "google-model-armor" "Google Model Armor" '{"kind":"google_model_armor","credential_source":"cloptima_managed","scan_directions":"input"}' false
run_provider "azure-content-safety" "Azure AI Content Safety" '{"kind":"azure_content_safety","credential_source":"cloptima_managed","prompt_shields_enabled":true,"harm_categories":["Hate","Violence"],"scan_directions":"input"}' false
run_provider "bedrock-guardrails" "Amazon Bedrock Guardrails" '{"kind":"bedrock_guardrails","credential_source":"cloptima_managed","scan_directions":"input"}' true

if [ "${#FAILURES[@]}" -gt 0 ]; then
  printf 'Provider checks failed: %s\n' "${FAILURES[*]}" >&2
  exit 1
fi
echo "All three isolated managed provider scans completed successfully."
echo "Review policy and request records in the console: $CONSOLE_POLICIES and $CONSOLE_AUDIT"
