#!/usr/bin/env bash
# Compliance policy that allows only Vertex AI. A request for a non-Vertex model is blocked
# before provider egress, and the application falls back to an approved model.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./provider-deny.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== Enterprise Compliance: Provider Boundary Enforcement ==="
echo ""

# Governance setup: a compliance policy that allows only Vertex AI. Platform admins normally
# create it once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at
# a key whose policy already matches.
get_access "provider-boundary-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "provider-boundary-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model]}')"

# Application code: try the preferred model, fall back to an approved one if the gateway blocks it.
process_record() {
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$1" '{model: $model, messages: [{role: "user", content: "Process confidential compliance record."}]}')")
}

echo "--- Step 1: Requesting an Unauthorized Provider (openai/gpt-4o) ---"
process_record "openai/gpt-4o"
FALLBACK_NEEDED=false
if [ "$HTTP_CODE" = "403" ]; then
  echo "Gateway compliance block (HTTP 403):"
  describe_block
  echo ""
  echo "Application recovery: non-compliant provider request intercepted. Routing to an authorized Vertex AI model..."
  FALLBACK_NEEDED=true
else
  echo "Processed unexpectedly (HTTP $HTTP_CODE)."
fi

if [ "$FALLBACK_NEEDED" = true ]; then
  echo ""
  echo "--- Step 2: Fallback to Approved Model ($MODEL_DEFAULT) ---"
  process_record "$MODEL_DEFAULT"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Assistant: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")"
    echo "Workload fulfilled on compliant infrastructure."
  else
    echo "Recovery failed (HTTP $HTTP_CODE):"; describe_block
  fi
fi

echo ""
echo "Review provider restriction audit logs in the Cloptima Console:"
echo "  - Audit Trail: $CONSOLE_AUDIT"
echo "  - Policies: $CONSOLE_POLICIES"
