#!/usr/bin/env bash
# Uses the ai:admin key to bring your own provider credential: create it,
# test it, then route one managed-gateway call through it so your own key
# gets Cloptima's governance/attribution/telemetry layer on top - billed to
# your own provider account, not Cloptima's managed-credits wallet.
# Requires PROVIDER_API_KEY (your own OpenAI-compatible key) in .env.
# Run standalone: ./byok.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

: "${PROVIDER_API_KEY:?Set PROVIDER_API_KEY to your own OpenAI-compatible provider key}"

SUFFIX="$(run_suffix)"
APP_ID="byok-$SUFFIX"

echo "Creating a provider credential (BYOK)..."
CREATE_VARS=$(jq -n --arg apiKey "$PROVIDER_API_KEY" --arg displayName "byok-openai-$SUFFIX" \
  '{input: {provider: "openai", displayName: $displayName, apiKey: $apiKey}}')
CREATE_RESULT=$(graphql 'mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
  createLLMProviderCredential(input: $input) { id provider displayName }
}' "$CREATE_VARS")
CREDENTIAL_ID=$(echo "$CREATE_RESULT" | jq -r '.createLLMProviderCredential.id')
echo "Created credential $CREDENTIAL_ID ($(echo "$CREATE_RESULT" | jq -r '.createLLMProviderCredential.displayName'))"

echo "Testing the credential against a model..."
TEST_VARS=$(jq -n --arg id "$CREDENTIAL_ID" '{id: $id, input: {model: "gpt-4o-mini"}}')
graphql 'mutation TestCredential($id: ID!, $input: TestLLMProviderCredentialInput) {
  testLLMProviderCredential(id: $id, input: $input) { id provider displayName }
}' "$TEST_VARS" | jq '.'

echo "Creating a policy allowing the BYOK provider/model and minting a key..."
POLICY=$(create_policy "$(jq -n --arg name "byok-$SUFFIX" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["openai"], allowedModels: ["openai/gpt-4o-mini"]}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
KEY=$(create_virtual_key "$(jq -n --arg name "vk-byok-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Making one managed-gateway call routed through the BYOK credential..."
echo ""

CALL_BODY=$(jq -n '{model: "openai/gpt-4o-mini", messages: [{role: "user", content: "In one sentence, confirm this call used a bring-your-own-key provider credential."}]}')
curl -sS -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
  -H "x-cloptima-provider-credential-id: $CREDENTIAL_ID" \
  -H "x-cloptima-team: Platform AI" -H "x-cloptima-app: $APP_ID" -H "x-cloptima-environment: dev" \
  -d "$CALL_BODY" | jq '.'

echo ""
echo "This call is billed to your own provider account, not Cloptima's managed-credit wallet."
echo "Evidence: Credentials tab ($CONSOLE_CREDENTIALS) shows the provider credential just created; Audit tab ($CONSOLE_AUDIT) and Explorer tab ($CONSOLE_SPEND) confirm attribution/telemetry are still captured even though spend is BYOK."
