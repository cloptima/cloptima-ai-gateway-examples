#!/usr/bin/env bash
# Demonstrates integrating managed third-party guardrail providers (Google Model Armor,
# Azure AI Content Safety, Amazon Bedrock Guardrails) through Cloptima-managed credentials.
# Each scan is billable and requires available Cloptima managed credits.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the profile, policy, and key). See .env.example.
# Run standalone: ./guardrail-detector-categories.sh
# Choose a provider with GUARDRAIL_PROVIDER (default google-model-armor):
#   GUARDRAIL_PROVIDER=azure-content-safety ./guardrail-detector-categories.sh
#   GUARDRAIL_PROVIDER=bedrock-guardrails ./guardrail-detector-categories.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
GUARDRAIL_PROVIDER="${GUARDRAIL_PROVIDER:-google-model-armor}"

case "$GUARDRAIL_PROVIDER" in
  azure-content-safety)
    PROVIDER_NAME="Azure AI Content Safety"
    INTEGRATION='{"kind":"azure_content_safety","credential_source":"cloptima_managed","prompt_shields_enabled":true,"harm_categories":["Hate","Violence"],"scan_directions":"input"}'
    ;;
  bedrock-guardrails)
    PROVIDER_NAME="Amazon Bedrock Guardrails"
    INTEGRATION='{"kind":"bedrock_guardrails","credential_source":"cloptima_managed","scan_directions":"input"}'
    ;;
  google-model-armor)
    PROVIDER_NAME="Google Model Armor"
    INTEGRATION='{"kind":"google_model_armor","credential_source":"cloptima_managed","scan_directions":"input"}'
    ;;
  *)
    echo "Unknown GUARDRAIL_PROVIDER \"$GUARDRAIL_PROVIDER\". Use one of: google-model-armor, azure-content-safety, bedrock-guardrails." >&2
    exit 1
    ;;
esac

echo "=== Multi-Provider Managed Guardrail Evaluation ==="
echo "Prerequisite: The account must have managed credits available for billable guardrail scans."
echo "Active Provider Integration: $PROVIDER_NAME"
echo ""

PROFILE_JSON=$(jq -n --argjson integration "$INTEGRATION" '{
  name: "managed-guardrail-profile",
  description: "Managed provider scan integration example",
  definition: {
    input: {action: "observe", detectors: {secret: {}}},
    output: {action: "observe", detectors: {secret: {}}},
    provider_integration: $integration
  }
}')

POLICY_JSON=$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "managed-guardrail-policy",
  mode: "enforce",
  budgetMode: "hard",
  failMode: "fail_closed",
  allowedProviders: ["vertex_ai"],
  allowedModels: [$model]
}')

get_access "guardrail-$GUARDRAIL_PROVIDER-demo" "$POLICY_JSON" "$PROFILE_JSON"

echo "Sending request through guarded route (pre-flight scan active)..."
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" '{model: $model, messages: [{role: "user", content: "Confirm this request passed safety scan."}]}')")

if [ "$HTTP_CODE" = "200" ]; then
  echo "  ✓ Scan completed & response served: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")"
  echo "  Tokens: $(jq -r '.usage.total_tokens' "$RESP_BODY_FILE") | Request ID: $(jq -r '.id' "$RESP_BODY_FILE")"
elif [ "$HTTP_CODE" = "403" ]; then
  echo "  🛡️ Gateway Security Block (HTTP 403)"
  describe_block
else
  echo "  Request returned unexpected HTTP $HTTP_CODE"
  describe_block
fi

echo ""
echo "Review guardrail scan events in the Cloptima Console:"
echo "  - Audit Trail: $CONSOLE_AUDIT"
echo "  - Policies: $CONSOLE_POLICIES"
