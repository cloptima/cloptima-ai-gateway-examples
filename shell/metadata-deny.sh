#!/usr/bin/env bash
# Creates a policy requiring attribution metadata, but mints its virtual key
# deliberately WITHOUT team/app/environment and binds it by principalId
# instead - the only way to produce a genuine missing-attribution block,
# since a key with baked-in team/app/environment is trusted as an
# attribution fallback when headers are absent. Calling with zero headers on
# this deliberately unscoped key trips a more fundamental gate before the
# policy's own required-metadata check ever runs.
# Run standalone: ./metadata-deny.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"

echo "Creating a policy that requires team_id/app_id/environment metadata..."
POLICY=$(create_policy "$(jq -n --arg name "metadata-deny-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    metadata: {required_metadata_keys: ["team_id", "app_id", "environment"]}}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

echo "Minting a key with NO team/app/environment on purpose..."
KEY=$(create_virtual_key "$(jq -n --arg name "vk-metadata-deny-$SUFFIX" '{name: $name}')")
KEY_ID=$(echo "$KEY" | jq -r '.id')
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')

echo "Binding by the key's own principalId (not team/app/environment)..."
# A principalId-only binding has no team/app/environment to distinguish its
# scope, so it always overlaps every other binding in the org - acknowledging
# that is required, not optional here.
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg principalId "$KEY_ID" \
  '{policyId: $policyId, principalId: $principalId, actorType: "service", priority: 5, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $KEY_ID, bound. Calling with zero attribution headers..."
echo ""

call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" \
  "This call should be denied - the key is deliberately unscoped and no attribution metadata is sent." \
  "metadata-deny-probe"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Expected: 400 - \"Managed AI requests require Cloptima team and app attribution\" - a more basic gate"
echo "than the policy engine's own required_metadata_keys check, but a genuine block either way."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by key $KEY_ID for the missing-attribution block record."
