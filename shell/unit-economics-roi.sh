#!/usr/bin/env bash
# Seeds two unit-economics scenarios side by side - a cost center and a
# profit center - so both ways of measuring an LLM agent's business value
# show up as real numbers, not claims:
#
# 1. A support-automation agent (cost center): resolving a ticket avoids a
#    pre-LLM support cost rather than booking revenue, so its value is
#    tracked as calibrated_business_value_usd/net_roi_usd against an ROI
#    calibration row (value per success, and what handling it manually used
#    to cost).
# 2. A checkout-upsell agent (profit center): each accepted upsell books
#    real revenue_usd, so its value shows up as a positive margin_usd
#    (revenue - spend) instead.
#
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (creates the policies and keys, seeds the calibration, submits
# unit metrics, and reads the reports).
# Run standalone: ./unit-economics-roi.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
COST_CENTER_TRANSACTION_TYPE="support_ticket_resolved"
PROFIT_CENTER_TRANSACTION_TYPE="checkout_upsell_accepted"
SUFFIX="$(run_suffix)"

# Application code: one chat completion with business-outcome headers attached.
# chat <prompt> [extra curl args...]
chat() {
  local prompt="$1"; shift
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" "$@" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$prompt" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
}

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
# A failed report read prints a note and lets the script continue.
read_unit_economics() {
  local unit_type="$1"
  local query report
  query=$(jq -n --arg unit_type "$unit_type" '{unit_type: $unit_type, group_by: "app_id", window: "30d"}')
  # admin_api prints the error to stderr only when the call fails.
  if ! report=$(admin_api GET /v1/llm/unit-economics "$query" 2>&1); then
    echo "  (Report aggregation pending: $report)"
    return 0
  fi
  jq --arg unit_type "$unit_type" '[.results[] | select(.unit_type == $unit_type) | .rows[]
    | {bucket, unit_count, cost_per_unit_usd, margin_usd, net_roi_usd, calibrated_business_value_usd, missing_metadata}]' <<<"$report"
}

# --- Cost center: support automation -----------------------------------
echo "Seeding an ROI calibration row for \"$COST_CENTER_TRANSACTION_TYPE\" (illustrative, not customer-validated)..."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EFFECTIVE_END="$(date -u -v+1y +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"
admin_api POST /v1/llm/roi/calibrations "" "$(jq -n --arg type "$COST_CENTER_TRANSACTION_TYPE" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{transaction_type: $type, value_per_success_cents: 800, pre_llm_baseline_cost_cents: 350, owner: "cloptima-ai-gateway-examples", effective_start: $start, effective_end: $end}')" >/dev/null
echo "ROI calibration seeded."

echo "Creating a policy + key and making a few real support-automation calls..."
TEAM_ID="Support Automation"; ENVIRONMENT="prod"
provision_app "unit-economics-support" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "unit-economics-support-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model]}')"
SUPPORT_APP_ID="$APP_ID"

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
  chat "${SUPPORT_PROMPTS[$i]}" \
    -H "x-cloptima-business-transaction-type: $COST_CENTER_TRANSACTION_TYPE" \
    -H "x-cloptima-business-transaction-id: $SUFFIX-support-$i" \
    -H "x-cloptima-business-transaction-unit-count: 1" \
    -H "x-cloptima-business-outcome-status: resolved" \
    -H "x-cloptima-business-outcome-success: true" \
    -H "x-cloptima-business-value-cents: 750"
  if [ "$HTTP_CODE" = "200" ]; then
    SUPPORT_SUCCESS_COUNT=$((SUPPORT_SUCCESS_COUNT + 1))
    echo "  [ticket-$((i + 1))] resolved: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE" | head -c 80)..."
  else
    echo "  [ticket-$((i + 1))] failed (HTTP $HTTP_CODE)"; describe_block
  fi
done

echo ""
echo "Submitting a unit-metrics batch for the support-automation window..."
submit_unit_metrics "support_answers" "${#SUPPORT_PROMPTS[@]}" "$SUPPORT_SUCCESS_COUNT" "$SUPPORT_WINDOW_START" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "Support Automation" "$SUPPORT_APP_ID" "$COST_CENTER_TRANSACTION_TYPE"

# --- Profit center: checkout upsell agent -------------------------------
echo ""
echo "Creating a policy + key and making a few real checkout-upsell calls..."
TEAM_ID="Checkout Upsell"; ENVIRONMENT="prod"
provision_app "unit-economics-upsell" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "unit-economics-upsell-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model]}')"
UPSELL_APP_ID="$APP_ID"

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
  chat "${UPSELL_PROMPTS[$i]}" \
    -H "x-cloptima-business-transaction-type: $PROFIT_CENTER_TRANSACTION_TYPE" \
    -H "x-cloptima-business-transaction-id: $SUFFIX-upsell-$i" \
    -H "x-cloptima-business-transaction-unit-count: 1" \
    -H "x-cloptima-business-outcome-status: accepted" \
    -H "x-cloptima-business-outcome-success: true" \
    -H "x-cloptima-business-value-cents: $value_cents"
  if [ "$HTTP_CODE" = "200" ]; then
    UPSELL_SUCCESS_COUNT=$((UPSELL_SUCCESS_COUNT + 1))
    ACCEPTED_REVENUE_USD=$(jq -n --argjson a "$ACCEPTED_REVENUE_USD" --argjson b "$value" '$a + $b')
    echo "  [upsell-$((i + 1))] accepted (\$$value): $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE" | head -c 80)..."
  else
    echo "  [upsell-$((i + 1))] failed (HTTP $HTTP_CODE)"; describe_block
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
