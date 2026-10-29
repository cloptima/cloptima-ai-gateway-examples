#!/usr/bin/env bash
# Scheduled job under a small per-policy daily budget. Calls are admitted until the budget is
# spent, then the gateway returns HTTP 402 and the job stops non-critical work.
#
# A hard budget reserves against an ESTIMATED cost derived from the request's max_tokens (a
# pessimistic worst case), not the realized post-completion cost, so every call passes a modest
# explicit max_tokens to keep that estimate small and consistent.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./budget-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
# Illustrative, not a platform minimum. Bounds: daily_budget_usd accepts more than 0, up to 10,000,000.
DAILY_BUDGET_USD="0.001"
MAX_TOKENS_PER_CALL=100
MAX_CALLS=60

echo "=== FinOps: Multi-Tenant Cost Governance & Budget Caps ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "budget-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson budget "$DAILY_BUDGET_USD" '{
  name: "budget-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model], daily_budget_usd: $budget}')"

# Application code: run tasks until the gateway reports the budget is exhausted.
echo "Executing workload under a policy with a \$$DAILY_BUDGET_USD daily budget cap (max $MAX_CALLS calls)..."
echo ""
SUCCESSFUL_CALLS=0
BUDGET_TRIPPED=false
for i in $(seq 1 "$MAX_CALLS"); do
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "Task #$i: Generate a short status update." --argjson max "$MAX_TOKENS_PER_CALL" \
      '{model: $model, max_tokens: $max, messages: [{role: "user", content: $prompt}]}')")
  case "$HTTP_CODE" in
    200)
      SUCCESSFUL_CALLS=$((SUCCESSFUL_CALLS + 1))
      echo "[Call $i] Allowed - Tokens: $(jq -r '.usage.total_tokens' "$RESP_BODY_FILE")"
      ;;
    402 | 403 | 429)
      BUDGET_TRIPPED=true
      echo ""
      echo "[Call $i] Gateway budget limit intercepted (HTTP $HTTP_CODE)"
      describe_block
      echo ""
      echo "Application FinOps action: daily budget reached. Halting non-critical requests and alerting FinOps."
      break
      ;;
    *)
      echo "[Call $i] Unexpected response (HTTP $HTTP_CODE)" >&2
      describe_block >&2
      exit 1
      ;;
  esac
done

echo ""
echo "Summary:"
echo "  - Successful calls admitted: $SUCCESSFUL_CALLS"
echo "  - Budget limit enforced: $([ "$BUDGET_TRIPPED" = true ] && echo Yes || echo 'Quota not exhausted yet')"
echo ""
echo "Review allocated spend and team attribution in the Cloptima Console:"
echo "  - Spend Explorer: $CONSOLE_SPEND"
echo "  - Budget Policies: $CONSOLE_POLICIES"
