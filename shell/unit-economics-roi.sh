#!/usr/bin/env bash
# Seeds two unit-economics scenarios side by side - a cost center and a
# profit center - so both ways of measuring an LLM agent's business value
# show up as real numbers, not claims:
#
# 1. A support-automation agent (cost center): resolving a ticket avoids a
#    pre-LLM support cost rather than booking revenue, so its value is
#    tracked as calibratedBusinessValueUsd/netRoiUsd against an ROI
#    calibration row (value per success, and what handling it manually used
#    to cost).
# 2. A checkout-upsell agent (profit center): each accepted upsell books
#    real revenue_usd, so its value shows up as a positive marginUsd
#    (revenue - spend) instead.
#
# Run standalone: ./unit-economics-roi.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
COST_CENTER_TRANSACTION_TYPE="support_ticket_resolved"
PROFIT_CENTER_TRANSACTION_TYPE="checkout_upsell_accepted"
SUFFIX="$(run_suffix)"

# submit_unit_metrics <unit_type> <unit_count> <success_count> <window_start> <window_end> <team_id> <app_id> <transaction_type> [revenue_usd]
submit_unit_metrics() {
  local unit_type="$1" unit_count="$2" success_count="$3" window_start="$4" window_end="$5" team_id="$6" app_id="$7" transaction_type="$8" revenue_usd="${9:-}"
  local body
  if [ -n "$revenue_usd" ]; then
    body=$(jq -n --arg unitType "$unit_type" --argjson count "$unit_count" --argjson success "$success_count" \
      --arg start "$window_start" --arg end "$window_end" --arg teamId "$team_id" --arg appId "$app_id" \
      --arg type "$transaction_type" --arg revenue "$revenue_usd" '
      {metrics: [{unit_type: $unitType, unit_count: $count, successful_unit_count: $success, window_start: $start, window_end: $end, team_id: $teamId, app_id: $appId, environment: "prod", business_transaction_type: $type, revenue_usd: $revenue}]}')
  else
    body=$(jq -n --arg unitType "$unit_type" --argjson count "$unit_count" --argjson success "$success_count" \
      --arg start "$window_start" --arg end "$window_end" --arg teamId "$team_id" --arg appId "$app_id" \
      --arg type "$transaction_type" '
      {metrics: [{unit_type: $unitType, unit_count: $count, successful_unit_count: $success, window_start: $start, window_end: $end, team_id: $teamId, app_id: $appId, environment: "prod", business_transaction_type: $type}]}')
  fi
  curl -sS -X POST "$BASE_URL/v1/ai/integrations/unit-metrics" \
    -H "Authorization: Bearer $CLOPTIMA_AI_ADMIN_KEY" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$body" -w "\n  status=%{http_code}\n"
}

# read_unit_economics <unit_type>
read_unit_economics() {
  local unit_type="$1"
  local vars
  vars=$(jq -n --arg unitType "$unit_type" '{unitType: $unitType, groupBy: "app_id", window: "30d"}')
  graphql 'query UnitEconomics($unitType: String!, $groupBy: String!, $window: String) {
    llmUnitEconomics(unitType: $unitType, groupBy: $groupBy, window: $window) {
      rows { bucket unitCount costPerUnitUsd marginUsd netRoiUsd calibratedBusinessValueUsd missingMetadata }
    }
  }' "$vars" | jq '.llmUnitEconomics.rows'
}

# --- Cost center: support automation -----------------------------------
SUPPORT_APP_ID="unit-economics-support-$SUFFIX"
echo "Seeding an ROI calibration row for \"$COST_CENTER_TRANSACTION_TYPE\" (illustrative, not customer-validated)..."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EFFECTIVE_END="$(date -u -v+1y +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"
ROI_VARS=$(jq -n --arg type "$COST_CENTER_TRANSACTION_TYPE" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{input: {transactionType: $type, valuePerSuccessCents: 800, preLlmBaselineCostCents: 350, owner: "cloptima-ai-gateway-examples", effectiveStart: $start, effectiveEnd: $end}}')
graphql 'mutation UpsertROI($input: UpsertROICalibrationInput!) { upsertROICalibration(input: $input) { id } }' "$ROI_VARS" >/dev/null
echo "ROI calibration seeded."

echo "Creating a policy + key and making a few real support-automation calls..."
SUPPORT_POLICY=$(create_policy "$(jq -n --arg name "unit-economics-support-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model]}')")
SUPPORT_POLICY_ID=$(echo "$SUPPORT_POLICY" | jq -r '.id')
SUPPORT_KEY=$(create_virtual_key "$(jq -n --arg name "vk-unit-economics-support-$SUFFIX" --arg appId "$SUPPORT_APP_ID" \
  '{name: $name, teamId: "Support Automation", appId: $appId, environment: "prod"}')")
SUPPORT_ACCESS_TOKEN=$(echo "$SUPPORT_KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$SUPPORT_POLICY_ID" --arg appId "$SUPPORT_APP_ID" \
  '{policyId: $policyId, teamId: "Support Automation", appId: $appId, environment: "prod", priority: 10, acknowledgeOverlap: true}')" >/dev/null

# The unit-metrics window is anchored to the calibration's own effective
# start, since the report only counts calibrated business value for the
# portion of the window the calibration was active for.
SUPPORT_WINDOW_START="$NOW"
SUPPORT_PROMPTS=(
  "A customer says their invoice total looks wrong for this month. Draft a short reply asking for the invoice number."
  "A customer cannot log in after resetting their password. Draft a short reply with the next step."
  "A customer wants to know why their monthly bill increased. Draft a short reply."
)
SUPPORT_SUCCESS_COUNT=0
for i in "${!SUPPORT_PROMPTS[@]}"; do
  call_chat "$SUPPORT_ACCESS_TOKEN" "$MODEL_DEFAULT" "${SUPPORT_PROMPTS[$i]}" "support-ticket-$((i + 1))" \
    "x-cloptima-team: Support Automation" "x-cloptima-app: $SUPPORT_APP_ID" "x-cloptima-environment: prod" \
    "x-cloptima-business-transaction-type: $COST_CENTER_TRANSACTION_TYPE" "x-cloptima-business-transaction-id: $SUFFIX-support-$i" \
    "x-cloptima-business-transaction-unit-count: 1" "x-cloptima-business-outcome-status: resolved" \
    "x-cloptima-business-value-cents: 750"
  if [ "$LAST_OUTCOME" = "allowed" ]; then SUPPORT_SUCCESS_COUNT=$((SUPPORT_SUCCESS_COUNT + 1)); fi
done

echo ""
echo "Submitting a unit-metrics batch for the support-automation window..."
submit_unit_metrics "support_answers" "${#SUPPORT_PROMPTS[@]}" "$SUPPORT_SUCCESS_COUNT" "$SUPPORT_WINDOW_START" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "Support Automation" "$SUPPORT_APP_ID" "$COST_CENTER_TRANSACTION_TYPE"

# --- Profit center: checkout upsell agent -------------------------------
UPSELL_APP_ID="unit-economics-upsell-$SUFFIX"
echo ""
echo "Creating a policy + key and making a few real checkout-upsell calls..."
UPSELL_POLICY=$(create_policy "$(jq -n --arg name "unit-economics-upsell-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model]}')")
UPSELL_POLICY_ID=$(echo "$UPSELL_POLICY" | jq -r '.id')
UPSELL_KEY=$(create_virtual_key "$(jq -n --arg name "vk-unit-economics-upsell-$SUFFIX" --arg appId "$UPSELL_APP_ID" \
  '{name: $name, teamId: "Checkout Upsell", appId: $appId, environment: "prod"}')")
UPSELL_ACCESS_TOKEN=$(echo "$UPSELL_KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$UPSELL_POLICY_ID" --arg appId "$UPSELL_APP_ID" \
  '{policyId: $policyId, teamId: "Checkout Upsell", appId: $appId, environment: "prod", priority: 10, acknowledgeOverlap: true}')" >/dev/null

UPSELL_WINDOW_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
UPSELL_PROMPTS=(
  "A customer just added running shoes to their cart. Write a one-sentence checkout upsell for moisture-wicking socks."
  "A customer just added a laptop to their cart. Write a one-sentence checkout upsell for a protective sleeve."
  "A customer just added a coffee maker to their cart. Write a one-sentence checkout upsell for a bag of specialty coffee beans."
)
UPSELL_VALUES_USD=("12.99" "24.99" "16.99")
UPSELL_SUCCESS_COUNT=0
ACCEPTED_REVENUE_USD="0"
for i in "${!UPSELL_PROMPTS[@]}"; do
  value="${UPSELL_VALUES_USD[$i]}"
  value_cents=$(jq -n --argjson v "$value" '($v * 100) | round')
  call_chat "$UPSELL_ACCESS_TOKEN" "$MODEL_DEFAULT" "${UPSELL_PROMPTS[$i]}" "checkout-upsell-$((i + 1))" \
    "x-cloptima-team: Checkout Upsell" "x-cloptima-app: $UPSELL_APP_ID" "x-cloptima-environment: prod" \
    "x-cloptima-business-transaction-type: $PROFIT_CENTER_TRANSACTION_TYPE" "x-cloptima-business-transaction-id: $SUFFIX-upsell-$i" \
    "x-cloptima-business-transaction-unit-count: 1" "x-cloptima-business-outcome-status: accepted" \
    "x-cloptima-business-value-cents: $value_cents"
  echo "  (\$$value if accepted)"
  if [ "$LAST_OUTCOME" = "allowed" ]; then
    UPSELL_SUCCESS_COUNT=$((UPSELL_SUCCESS_COUNT + 1))
    ACCEPTED_REVENUE_USD=$(jq -n --argjson a "$ACCEPTED_REVENUE_USD" --argjson b "$value" '$a + $b')
  fi
done

echo ""
echo "Submitting a unit-metrics batch for the checkout-upsell window, with the real revenue those accepted upsells booked..."
submit_unit_metrics "checkout_upsells" "${#UPSELL_PROMPTS[@]}" "$UPSELL_SUCCESS_COUNT" "$UPSELL_WINDOW_START" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "Checkout Upsell" "$UPSELL_APP_ID" "$PROFIT_CENTER_TRANSACTION_TYPE" "$ACCEPTED_REVENUE_USD"

echo ""
echo "Reading back the cost-center report (support automation - value shows up as calibrated ROI, not margin)..."
read_unit_economics "support_answers"

echo ""
echo "Reading back the profit-center report (checkout upsell - value shows up as a positive margin from real revenue)..."
read_unit_economics "checkout_upsells"

echo ""
echo "Evidence: Economics tab ($CONSOLE_UNIT_ECONOMICS) shows both apps side by side - cost-per-unit, margin, and net-ROI, grouped by app."
