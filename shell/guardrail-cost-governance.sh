#!/usr/bin/env bash
# Per-request cost cap on a provider-backed guardrail scan (Google Model Armor, managed by
# Cloptima). The billable scan requires available Cloptima managed credits.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the profile, policy, and key). See .env.example.
# Run standalone: ./guardrail-cost-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
MAX_COST_PER_REQUEST_CENTS=1

echo "=== Guardrail Cost Governance: Per-Request Scan Cap ==="
echo "Prerequisite: the account must have managed credits available for billable guardrail scans."
echo ""

# Governance setup: a guardrail profile with a managed Model Armor scan and a per-request cost cap,
# attached to the policy this application runs under. Platform admins normally create these once in
# the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key whose policy
# already matches.
get_access "guardrail-cost-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "guardrail-cost-policy", mode: "enforce", budgetMode: "hard", failMode: "fail_closed",
  allowedProviders: ["vertex_ai"], allowedModels: [$model]}')" \
  "$(jq -n --argjson maxCostCents "$MAX_COST_PER_REQUEST_CENTS" '{
    name: "guardrail-cost-profile",
    description: "Managed Model Armor scan with a per-request cost cap",
    definition: {
      input: {action: "observe", detectors: {secret: {}}},
      output: {action: "observe", detectors: {secret: {}}},
      provider_integration: {kind: "google_model_armor", credential_source: "cloptima_managed", scan_directions: "input"},
      cost: {mode: "enforce", max_cost_per_request_cents: $maxCostCents, exceeded_action: "block"}}}')"

# Application code: a normal request through the guarded route.
echo "Sending a prompt through the guarded route..."
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" '{model: $model, messages: [{role: "user", content: "Confirm this request passed safety scan within cost budget."}]}')")
if [ "$HTTP_CODE" = "200" ]; then
  echo "Assistant: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")"
  echo "Scan outcome: admitted and served within the ${MAX_COST_PER_REQUEST_CENTS}¢ cap."
elif [ "$HTTP_CODE" = "403" ]; then
  echo "Scan cost exceeded the cap (HTTP 403):"; describe_block
else
  echo "Request failed (HTTP $HTTP_CODE):"; describe_block
fi

echo ""
echo "Review guardrail scans and policies in the Cloptima Console:"
echo "  - Audit: $CONSOLE_AUDIT"
echo "  - Policies: $CONSOLE_POLICIES"
