#!/usr/bin/env bash
# Demonstrates the generic governance queue for a manually-requested change,
# distinct from semantic-cache-enforce.sh's auto-queued entry. Requests a
# budget increase on an existing policy (approvalType 'budget_limit_change').
# Both requesting and deciding a change need an admin-or-owner identity, so
# an ai:admin key can do either. requestedChange uses the snake_case keys
# daily_budget_usd / monthly_budget_usd, not dailyBudgetUsd. It then lists
# the request pending alongside the approval-type registry itself. The
# actual approve/reject decision is deliberately NOT scripted here for the
# first request - reviewLLMGatewayApproval is a real, callable mutation, but
# this example stops at "request it, show it's pending" and leaves the
# decision to a second identity in the console's Audit tab, same as any real
# governance workflow would require. A second request at the end passes
# applyImmediately: true, which - since this key already qualifies to decide
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
echo "Creating a baseline policy with dailyBudgetUsd=\$$CURRENT_DAILY_BUDGET_USD..."
provision_app "governed-app-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson budget "$CURRENT_DAILY_BUDGET_USD" '{
  name: "governance-approval-policy", mode: "enforce", budgetMode: "hard",
  allowedProviders: ["vertex_ai"], allowedModels: [$model], dailyBudgetUsd: $budget}')"
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
echo "Requesting approval to raise dailyBudgetUsd from \$$CURRENT_DAILY_BUDGET_USD to \$$REQUESTED_DAILY_BUDGET_USD..."
COST_IMPACT_CENTS=$(( (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100 ))
APPROVAL=$(create_llm_gateway_approval "$(jq -n \
  --arg policyId "$POLICY_ID" --argjson requestedBudget "$REQUESTED_DAILY_BUDGET_USD" \
  --arg appId "$APP_ID" --argjson costImpactCents "$COST_IMPACT_CENTS" \
  '{approvalType: "budget_limit_change", targetId: $policyId,
    requestedChange: {daily_budget_usd: $requestedBudget},
    affectedApps: [$appId], affectedRoutes: ["/v1/ai/chat/completions"],
    expectedCostImpactCents: $costImpactCents,
    expectedRiskReduction: "none - this is a budget increase, not a risk-reducing change",
    metadata: {requestedBy: "approval-workflow example"}}')")
echo "  requested: $APPROVAL"
APPROVAL_ID=$(echo "$APPROVAL" | jq -r '.id')

echo ""
echo "Listing the approval-type registry and this request in the pending queue..."
REGISTRY=$(graphql 'query ApprovalTypes { llmApprovalTypes { type targetType requiredRole } }' '{}')
echo "  registry: $(echo "$REGISTRY" | jq -c '.llmApprovalTypes')"
PENDING=$(list_llm_gateway_approvals "pending" 50)
OURS=$(echo "$PENDING" | jq -c --arg id "$APPROVAL_ID" '.[] | select(.id == $id)')
echo "  this request, pending: $OURS"

echo "  status: $(echo "$OURS" | jq -r '.status // "not found"')"

echo ""
echo "The request waits in 'pending' status and the policy's dailyBudgetUsd stays at"
echo "\$$CURRENT_DAILY_BUDGET_USD until a second identity reviews and approves it via reviewLLMGatewayApproval -"
echo "not something this script does on its own behalf."

echo ""
echo "Requesting the same kind of budget increase again, this time with applyImmediately: true..."
REQUESTED_DAILY_BUDGET_USD_2=$((REQUESTED_DAILY_BUDGET_USD + 10))
COST_IMPACT_CENTS_2=$(( (REQUESTED_DAILY_BUDGET_USD_2 - CURRENT_DAILY_BUDGET_USD) * 100 ))
IMMEDIATE_APPROVAL=$(create_llm_gateway_approval "$(jq -n \
  --arg policyId "$POLICY_ID" --argjson requestedBudget "$REQUESTED_DAILY_BUDGET_USD_2" \
  --arg appId "$APP_ID" --argjson costImpactCents "$COST_IMPACT_CENTS_2" \
  '{approvalType: "budget_limit_change", targetId: $policyId,
    requestedChange: {daily_budget_usd: $requestedBudget},
    affectedApps: [$appId], affectedRoutes: ["/v1/ai/chat/completions"],
    expectedCostImpactCents: $costImpactCents,
    expectedRiskReduction: "none - this is a budget increase, not a risk-reducing change",
    metadata: {requestedBy: "approval-workflow example"},
    applyImmediately: true}')")
echo "  result: $IMMEDIATE_APPROVAL"

echo "  status: $(echo "$IMMEDIATE_APPROVAL" | jq -r '.status // "unknown"')"

echo ""
echo "With applyImmediately the status is 'applied', not 'pending' - since this key already qualifies to decide this itself,"
echo "the request is approved and applied in this same call, with no separate review step."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the first request still pending and this second one already applied; Policies tab ($CONSOLE_POLICIES) shows the policy's budget reflecting the applied change."
