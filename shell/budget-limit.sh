#!/usr/bin/env bash
# Creates a hard_strict policy with a small but real per-policy daily budget,
# distinct from the org-wide managed-credits wallet cap, and fires calls in a
# loop until the budget denies the rest.
#
# hard_strict reserves against an ESTIMATED cost derived from the request's
# max_tokens (a pessimistic worst case), not the realized post-completion
# cost - so every call here passes an explicit, modest max_tokens to keep
# that estimate small and consistent. Without that, an unbounded default
# max_tokens would make the very first call's estimate blow past a small
# budget and trip on call 1 regardless of the budget's actual size.
# Run standalone: ./budget-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum. Bounds: dailyBudgetUsd accepts 0-10,000,000.
DAILY_BUDGET_USD="0.01"
MAX_TOKENS_PER_CALL=100
MAX_CALLS=40
SUFFIX="$(run_suffix)"
APP_ID="budget-limit-$SUFFIX"

echo "Creating hard_strict policy with dailyBudgetUsd=\$$DAILY_BUDGET_USD..."
POLICY=$(create_policy "$(jq -n --arg name "budget-limit-$SUFFIX" --arg model "$MODEL_DEFAULT" --argjson budget "$DAILY_BUDGET_USD" \
  '{name: $name, mode: "enforce", budgetMode: "hard_strict", allowedProviders: ["vertex_ai"], allowedModels: [$model], dailyBudgetUsd: $budget}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-budget-limit-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Firing calls (max $MAX_CALLS) until the budget denies..."
echo ""

ALLOWED_COUNT=0
for i in $(seq 1 "$MAX_CALLS"); do
  BODY=$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "Budget probe $i. Reply with just \"ok\"." --argjson maxTokens "$MAX_TOKENS_PER_CALL" \
    '{model: $model, max_tokens: $maxTokens, messages: [{role: "user", content: $prompt}]}')
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-team: Platform AI" -H "x-cloptima-app: $APP_ID" -H "x-cloptima-environment: dev" -d "$BODY")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  [allowed] call-$i (http $HTTP_CODE)"
    ALLOWED_COUNT=$((ALLOWED_COUNT + 1))
  else
    echo "  [blocked] call-$i (http $HTTP_CODE)"
    break
  fi
done

echo ""
echo "$ALLOWED_COUNT calls allowed before the \$$DAILY_BUDGET_USD/day policy budget returned 402."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$APP_ID\" for the 402 block record; Explorer tab ($CONSOLE_SPEND) shows the spend accumulated right up to the cap."
