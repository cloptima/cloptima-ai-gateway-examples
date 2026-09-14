#!/usr/bin/env bash
# Enterprise contract price sheets and negotiated rate overrides apply to
# customer-owned provider accounts and credentials (bring-your-own-key / BYOK).
# When an enterprise negotiates custom pricing with a model provider, those
# contracted rates govern the customer's own provider keys. Cloptima's
# managed-credits wallet provides platform-funded compute at standard catalog
# rates, so negotiated price sheets apply strictly to BYOK credentials.
#
# Requires PROVIDER_API_KEY (your own OpenAI-compatible key) in .env.
# Run standalone: ./contract-pricing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

: "${PROVIDER_API_KEY:?Set PROVIDER_API_KEY to your own OpenAI-compatible provider key in .env}"

# openai/gpt-4o-mini retail: $0.15 in / $0.60 out per million tokens
# (Cloptima's default LLM pricing catalog). ~20% off both - a realistic
# volume discount for a negotiated enterprise agreement. No cached-token rate
# is negotiated here - a real procurement conversation prices input and
# output tokens, not a platform caching mechanism, so this leaves the cache
# rate unset and lets it resolve proportionally from retail instead of
# guessing a number.
PROVIDER="openai"
MODEL="gpt-4o-mini"
CANONICAL_MODEL="openai/gpt-4o-mini"
CONTRACT_INPUT_RATE="0.12"
CONTRACT_OUTPUT_RATE="0.48"
SUFFIX="$(run_suffix)"
APP_ID="contract-pricing-$SUFFIX"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EFFECTIVE_END="$(date -u -v+1y +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"

echo "Registering a provider credential (BYOK)..."
CREATE_CREDENTIAL_VARS=$(jq -n --arg apiKey "$PROVIDER_API_KEY" --arg displayName "byok-openai-$SUFFIX" \
  '{input: {provider: "openai", displayName: $displayName, apiKey: $apiKey}}')
CREATE_CREDENTIAL_RESULT=$(graphql 'mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
  createLLMProviderCredential(input: $input) { id provider displayName }
}' "$CREATE_CREDENTIAL_VARS")
CREDENTIAL_ID=$(echo "$CREATE_CREDENTIAL_RESULT" | jq -r '.createLLMProviderCredential.id')
echo "  credential $CREDENTIAL_ID ($(echo "$CREATE_CREDENTIAL_RESULT" | jq -r '.createLLMProviderCredential.displayName'))"

echo "Creating an illustrative enterprise price sheet (~20% off retail on $MODEL)..."
PRICE_SHEET_VARS=$(jq -n --arg name "Enterprise volume agreement ($SUFFIX)" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{input: {name: $name, owner: "cloptima-ai-gateway-examples", effectiveStart: $start, effectiveEnd: $end}}')
PRICE_SHEET=$(graphql 'mutation CreatePriceSheet($input: CreatePriceSheetInput!) { createPriceSheet(input: $input) { id name status } }' "$PRICE_SHEET_VARS")
PRICE_SHEET_ID=$(echo "$PRICE_SHEET" | jq -r '.createPriceSheet.id')
echo "  price sheet $(echo "$PRICE_SHEET" | jq -r '.createPriceSheet.name') -> $PRICE_SHEET_ID (status=$(echo "$PRICE_SHEET" | jq -r '.createPriceSheet.status'))"

echo "Adding the negotiated rate override..."
OVERRIDE_VARS=$(jq -n --arg priceSheetId "$PRICE_SHEET_ID" --arg provider "$PROVIDER" --arg model "$MODEL" \
  --argjson inputRate "$CONTRACT_INPUT_RATE" --argjson outputRate "$CONTRACT_OUTPUT_RATE" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{priceSheetId: $priceSheetId, overrides: [{provider: $provider, model: $model, inputRatePerMillion: $inputRate, outputRatePerMillion: $outputRate, effectiveStart: $start, effectiveEnd: $end}]}')
graphql 'mutation AddRateOverrides($priceSheetId: ID!, $overrides: [RateOverrideInput!]!) { addRateOverrides(priceSheetId: $priceSheetId, overrides: $overrides) { id provider model inputRatePerMillion outputRatePerMillion } }' \
  "$OVERRIDE_VARS" >/dev/null

echo "Approving the price sheet so it applies to real cost calculations..."
graphql 'mutation ApprovePriceSheet($id: ID!) { approvePriceSheet(id: $id) { id status approvedAt } }' \
  "$(jq -n --arg id "$PRICE_SHEET_ID" '{id: $id}')" >/dev/null

echo "Logging a commitment against this agreement..."
COMMITMENT_VARS=$(jq -n --arg name "Annual commitment ($SUFFIX)" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{input: {name: $name, type: "upfront", amountCents: "200000", currency: "USD", effectiveStart: $start, effectiveEnd: $end}}')
graphql 'mutation CreateCommitment($input: CreateCommitmentInput!) { createCommitmentEntry(input: $input) { id name amountCents } }' \
  "$COMMITMENT_VARS" >/dev/null

echo "Creating a policy + key and making real BYOK calls at the contracted rate..."
POLICY=$(create_policy "$(jq -n --arg name "contract-pricing-$SUFFIX" --arg model "$CANONICAL_MODEL" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["openai"], allowedModels: [$model]}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')
KEY=$(create_virtual_key "$(jq -n --arg name "vk-contract-pricing-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Finance", appId: $appId, environment: "prod"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Finance", appId: $appId, environment: "prod", priority: 10, acknowledgeOverlap: true}')" >/dev/null

PROMPTS=(
  "In one sentence, summarize why enterprise LLM contracts beat retail pricing."
  "In one sentence, explain what a committed-use discount is."
  "In one sentence, explain why effective cost differs from retail cost."
)
VERIFICATION_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ALLOWED_COUNT=0
for i in "${!PROMPTS[@]}"; do
  call_chat "$ACCESS_TOKEN" "$CANONICAL_MODEL" "${PROMPTS[$i]}" "contract-call-$((i + 1))" "x-cloptima-provider-credential-id: $CREDENTIAL_ID"
  if [ "$LAST_OUTCOME" = "allowed" ]; then
    ALLOWED_COUNT=$((ALLOWED_COUNT + 1))
  fi
done

if [ "$ALLOWED_COUNT" -ne "${#PROMPTS[@]}" ]; then
  echo "Expected all ${#PROMPTS[@]} calls to succeed, but only $ALLOWED_COUNT did - can't verify contracted pricing without real usage to check." >&2
  exit 1
fi

echo ""
echo "Verifying the contracted rate actually applied (checking the finance dashboard for real retail-vs-contracted numbers)..."
# Scoped to calls made by this run, not the whole account's history.
DASHBOARD=""
for attempt in 1 2 3 4 5; do
  if [ "$attempt" -gt 1 ]; then sleep 2; fi
  DASHBOARD_VARS=$(jq -n --arg startTime "$VERIFICATION_START" --arg endTime "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '{startTime: $startTime, endTime: $endTime}')
  RESULT=$(graphql 'query Dashboard($startTime: DateTime!, $endTime: DateTime!) { llmFinanceDashboard(window: "custom", startTime: $startTime, endTime: $endTime) { retailCostUsd contractedCostUsd hasActiveContract } }' "$DASHBOARD_VARS")
  DASHBOARD=$(echo "$RESULT" | jq -c 'select(.llmFinanceDashboard.hasActiveContract == true and (.llmFinanceDashboard.contractedCostUsd | tonumber) < (.llmFinanceDashboard.retailCostUsd | tonumber)) | .llmFinanceDashboard')
  if [ -n "$DASHBOARD" ]; then break; fi
done

if [ -z "$DASHBOARD" ]; then
  echo "Finance dashboard does not show contracted cost below retail cost after retrying - contract pricing does not appear to have applied." >&2
  exit 1
fi

RETAIL_USD=$(echo "$DASHBOARD" | jq -r '.retailCostUsd')
CONTRACTED_USD=$(echo "$DASHBOARD" | jq -r '.contractedCostUsd')
echo "  Confirmed: Finance dashboard shows real contracted cost \$$CONTRACTED_USD below retail cost \$$RETAIL_USD for this account."

echo ""
echo "Evidence: Dashboard tab ($CONSOLE_DASHBOARD) - Blended Effective Cost card shows retail vs. contracted vs. effective cost; open Contract Pricing to see this price sheet and its rate override."
