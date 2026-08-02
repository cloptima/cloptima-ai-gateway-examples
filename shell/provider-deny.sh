#!/usr/bin/env bash
# Creates a Vertex-only policy and requests a non-Vertex model through it,
# showing a provider-scope block rather than a silent fallback.
# Run standalone: ./provider-deny.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"
APP_ID="provider-deny-$SUFFIX"

echo "Creating a Vertex-only policy..."
POLICY=$(create_policy "$(jq -n --arg name "provider-deny-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model]}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-provider-deny-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Requesting a non-Vertex model through it..."
echo ""

call_chat "$ACCESS_TOKEN" "openai/gpt-4o" "This call should be denied - non-Vertex provider." \
  "provider-deny-probe" "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Expected: blocked (403) - the policy only allows vertex_ai, so a non-Vertex model is denied before provider egress."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$APP_ID\" for the provider-scope block record."
