#!/usr/bin/env bash
# Demonstrates the generic governance queue for a manually-requested change,
# distinct from semantic-cache-enforce.sh's auto-queued entry. Requests a
# budget increase on an existing policy (approval_type 'budget_limit_change').
# Both requesting and deciding a change need an admin-or-owner identity, so
# an ai:admin key can do either. requested_change uses the policy field names
# daily_budget_usd / monthly_budget_usd. It then lists the request pending
# alongside the approval-type registry itself. The actual approve/reject
# decision is deliberately NOT scripted here for the first request -
# POST /v1/llm/approvals/{approval_id}/review is a real, callable operation,
# but this example stops at "request it, show it's pending" and leaves the
# decision to a second identity in the console's Audit tab, same as any real
# governance workflow would require. A second request at the end passes
# apply_immediately: true, which - since this key already qualifies to decide
# this itself - skips that separate step and applies right away.
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (creates the policy and key, and requests approvals).
# Run standalone: ./approval-workflow.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
CURRENT_DAILY_BUDGET_USD=5
REQUESTED_DAILY_BUDGET_USD=25

# Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy, key,
# and binding once in the Console, Terraform, or CI.
echo "Creating a baseline policy with daily_budget_usd=\$$CURRENT_DAILY_BUDGET_USD..."
provision_app "governed-app-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson budget "$CURRENT_DAILY_BUDGET_USD" '{
  name: "governance-approval-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model], daily_budget_usd: $budget}')"
echo ""

# Application code: normal traffic is unaffected while a change request is pending.
echo "Making one call under the current (unchanged) policy..."
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" '{model: $model, messages: [{role: "user", content: "Confirm this application is running normally."}]}')")
echo "  Application status: HTTP $HTTP_CODE"

echo ""
echo "Requesting approval to raise daily_budget_usd from \$$CURRENT_DAILY_BUDGET_USD to \$$REQUESTED_DAILY_BUDGET_USD..."
COST_IMPACT_CENTS=$(( (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100 ))
APPROVAL=$(create_approval "$(jq -n \
  --arg policy_id "$POLICY_ID" --argjson requested_budget "$REQUESTED_DAILY_BUDGET_USD" \
  --arg app_id "$APP_ID" --argjson cost_impact_cents "$COST_IMPACT_CENTS" \
  '{approval_type: "budget_limit_change", target_id: $policy_id,
    requested_change: {daily_budget_usd: $requested_budget},
    affected_apps: [$app_id], affected_routes: ["/v1/ai/chat/completions"],
    expected_cost_impact_cents: $cost_impact_cents,
    expected_risk_reduction: "none - this is a budget increase, not a risk-reducing change"}')")
echo "  requested: $(jq -c '{id, approval_type, status, target_id, requested_at, required_approver_role}' <<<"$APPROVAL")"
APPROVAL_ID=$(jq -r '.id' <<<"$APPROVAL")

echo ""
echo "Listing the approval-type registry and this request in the pending queue..."
REGISTRY=$(admin_api GET /v1/llm/approval-types)
echo "  registry: $(jq -c '.items' <<<"$REGISTRY")"
PENDING=$(list_approvals '{"status": "pending", "limit": 50}')
OURS=$(jq -c --arg id "$APPROVAL_ID" '.items[] | select(.id == $id) | {id, approval_type, status, target_id, requested_at, required_approver_role}' <<<"$PENDING")
echo "  this request, pending: $OURS"

echo "  status: $(jq -rn --argjson ours "${OURS:-null}" '$ours.status // "not found"')"

echo ""
echo "The request waits in 'pending' status and the policy's daily_budget_usd stays at"
echo "\$$CURRENT_DAILY_BUDGET_USD until a second identity reviews and approves it via POST /v1/llm/approvals/{approval_id}/review -"
echo "not something this script does on its own behalf."

echo ""
echo "Requesting the same kind of budget increase again, this time with apply_immediately: true..."
REQUESTED_DAILY_BUDGET_USD_2=$((REQUESTED_DAILY_BUDGET_USD + 10))
COST_IMPACT_CENTS_2=$(( (REQUESTED_DAILY_BUDGET_USD_2 - CURRENT_DAILY_BUDGET_USD) * 100 ))
IMMEDIATE_APPROVAL=$(create_approval "$(jq -n \
  --arg policy_id "$POLICY_ID" --argjson requested_budget "$REQUESTED_DAILY_BUDGET_USD_2" \
  --arg app_id "$APP_ID" --argjson cost_impact_cents "$COST_IMPACT_CENTS_2" \
  '{approval_type: "budget_limit_change", target_id: $policy_id,
    requested_change: {daily_budget_usd: $requested_budget},
    affected_apps: [$app_id], affected_routes: ["/v1/ai/chat/completions"],
    expected_cost_impact_cents: $cost_impact_cents,
    expected_risk_reduction: "none - this is a budget increase, not a risk-reducing change",
    apply_immediately: true}')")
echo "  result: $(jq -c '{id, approval_type, status, target_id, requested_at, required_approver_role}' <<<"$IMMEDIATE_APPROVAL")"

echo "  status: $(echo "$IMMEDIATE_APPROVAL" | jq -r '.status // "unknown"')"

echo ""
echo "With apply_immediately the status is 'applied', not 'pending' - since this key already qualifies to decide this itself,"
echo "the request is approved and applied in this same call, with no separate review step."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the first request still pending and this second one already applied; Policies tab ($CONSOLE_POLICIES) shows the policy's budget reflecting the applied change."
