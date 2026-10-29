#!/usr/bin/env bash
# Enterprise contract price sheets and negotiated rate overrides apply to
# customer-owned provider accounts and credentials (bring-your-own-key / BYOK).
# When an enterprise negotiates custom pricing with a model provider, those
# contracted rates govern the customer's own provider keys. Cloptima's
# managed-credits wallet provides platform-funded compute at standard catalog
# rates, so negotiated price sheets apply strictly to BYOK credentials.
#
# Requires PROVIDER_API_KEY (your own OpenAI-compatible key) or CLOPTIMA_PROVIDER_CREDENTIAL_ID in .env.
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (creates the price sheet, policy, and key, and reads the finance dashboard).
# Run standalone: ./contract-pricing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

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

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EFFECTIVE_END="$(date -u -v+1y +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "${CLOPTIMA_PROVIDER_CREDENTIAL_ID:-}" ]; then
  CREDENTIAL_ID="$CLOPTIMA_PROVIDER_CREDENTIAL_ID"
  echo "Using registered provider credential ID: $CREDENTIAL_ID"
elif [ -n "${PROVIDER_API_KEY:-}" ]; then
  echo "Registering a provider credential (BYOK)..."
  CREDENTIAL=$(admin_api POST /v1/llm/provider-credentials "" "$(jq -n --arg api_key "$PROVIDER_API_KEY" --arg display_name "byok-openai-$SUFFIX" \
    '{provider: "openai", display_name: $display_name, api_key: $api_key}')")
  CREDENTIAL_ID=$(jq -r '.id' <<<"$CREDENTIAL")
  echo "  credential $CREDENTIAL_ID ($(jq -r '.display_name' <<<"$CREDENTIAL"))"
else
  echo "Set PROVIDER_API_KEY (or CLOPTIMA_PROVIDER_CREDENTIAL_ID) in .env (see .env.example)." >&2
  exit 1
fi

echo "Creating an illustrative enterprise price sheet (~20% off retail on $MODEL)..."
PRICE_SHEET=$(admin_api POST /v1/llm/pricing/sheets "" "$(jq -n --arg name "Enterprise volume agreement ($SUFFIX)" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{name: $name, owner: "cloptima-ai-gateway-examples", effective_start: $start, effective_end: $end}')")
PRICE_SHEET_ID=$(jq -r '.id' <<<"$PRICE_SHEET")
echo "  price sheet $(jq -r '.name' <<<"$PRICE_SHEET") -> $PRICE_SHEET_ID (status=$(jq -r '.status' <<<"$PRICE_SHEET"))"

echo "Adding the negotiated rate override..."
admin_api POST "/v1/llm/pricing/sheets/$(urlencode "$PRICE_SHEET_ID")/overrides" "" "$(jq -n --arg provider "$PROVIDER" --arg model "$MODEL" \
  --argjson input_rate "$CONTRACT_INPUT_RATE" --argjson output_rate "$CONTRACT_OUTPUT_RATE" --arg start "$NOW" --arg end "$EFFECTIVE_END" '
{overrides: [{provider: $provider, model: $model, input_rate_per_million: $input_rate, output_rate_per_million: $output_rate, effective_start: $start, effective_end: $end}]}')" >/dev/null

echo "Approving the price sheet so it applies to real cost calculations..."
admin_api POST "/v1/llm/pricing/sheets/$(urlencode "$PRICE_SHEET_ID")/approve" >/dev/null

# Governance setup: a policy for the BYOK provider and model. Platform admins normally create it
# once in the Console, Terraform, or CI.
echo "Creating a policy + key..."
TEAM_ID="Finance"; ENVIRONMENT="prod"
provision_app "contract-pricing-demo" "$(jq -n --arg provider "$PROVIDER" --arg model "$CANONICAL_MODEL" '{
  name: "contract-pricing-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: [$provider], allowed_models: [$model]}')"

# Application code: the credential header routes each call through your own provider account,
# which is where the negotiated rates apply.
PROMPTS=(
  "In one sentence, summarize why enterprise LLM contracts beat retail pricing."
  "In one sentence, explain what a committed-use discount is."
  "In one sentence, explain why effective cost differs from retail cost."
)
VERIFICATION_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ALLOWED_COUNT=0
for i in "${!PROMPTS[@]}"; do
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-provider-credential-id: $CREDENTIAL_ID" \
    -d "$(jq -n --arg model "$CANONICAL_MODEL" --arg prompt "${PROMPTS[$i]}" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
  if [ "$HTTP_CODE" = "200" ]; then
    ALLOWED_COUNT=$((ALLOWED_COUNT + 1))
    echo "  [query-$((i + 1))] $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE" | head -c 100)... (in=$(jq -r '.usage.prompt_tokens' "$RESP_BODY_FILE"), out=$(jq -r '.usage.completion_tokens' "$RESP_BODY_FILE"))"
  else
    echo "  [query-$((i + 1))] failed (HTTP $HTTP_CODE)"; describe_block
  fi
done

if [ "$ALLOWED_COUNT" -ne "${#PROMPTS[@]}" ]; then
  echo "Only $ALLOWED_COUNT of ${#PROMPTS[@]} calls succeeded - cannot verify contracted pricing without real usage to check." >&2
  exit 1
fi

echo ""
echo "Verifying the contracted rate actually applied (checking the finance dashboard for real retail-vs-contracted numbers)..."
# Scoped to calls made by this run, not the whole account's history.
DASHBOARD=""
for attempt in 1 2 3 4 5; do
  if [ "$attempt" -gt 1 ]; then sleep 2; fi
  # A failed read is retried, like a dashboard that does not show the contract yet.
  if RESULT=$(admin_api GET /v1/llm/finance/dashboard "$(jq -n --arg start_time "$VERIFICATION_START" --arg end_time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{window: "custom", start_time: $start_time, end_time: $end_time}')" 2>/dev/null); then
    DASHBOARD=$(jq -c 'select(.has_active_contract == true and .contracted_cost_usd != null and (.contracted_cost_usd | tonumber) < (.retail_cost_usd | tonumber))' <<<"$RESULT")
    if [ -n "$DASHBOARD" ]; then break; fi
  fi
done

if [ -z "$DASHBOARD" ]; then
  echo "Finance dashboard does not show contracted cost below retail cost after retrying - contract pricing does not appear to have applied." >&2
  exit 1
fi

RETAIL_USD=$(jq -r '.retail_cost_usd' <<<"$DASHBOARD")
CONTRACTED_USD=$(jq -r '.contracted_cost_usd' <<<"$DASHBOARD")
echo "  Confirmed: Finance dashboard shows real contracted cost \$$CONTRACTED_USD below retail cost \$$RETAIL_USD for this account."

echo ""
echo "Evidence: Dashboard tab ($CONSOLE_DASHBOARD) - Blended Effective Cost card shows retail vs. contracted vs. effective cost; open Contract Pricing to see this price sheet and its rate override."
