#!/usr/bin/env bash
# Customer support assistant under a guardrail profile. A normal question is served. A message
# containing a US SSN is blocked before it reaches the model, and the application returns a
# friendly fallback instead of failing or leaking the identifier.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the profile, policy, and key). See .env.example.
# Run standalone: ./pii-guardrail.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== Customer Support Assistant: PII & Guardrails ==="
echo ""

# Governance setup: a guardrail profile that blocks credentials and US SSN formats on input,
# attached to the policy this application runs under. Platform admins normally create these
# once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key
# whose policy already matches.
get_access "support-bot-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "support-guardrail-policy", mode: "enforce", budgetMode: "hard", failMode: "fail_closed",
  allowedProviders: ["vertex_ai"], allowedModels: [$model]}')" \
  "$(jq -n '{
    name: "support-guardrail-profile",
    description: "Customer support safety profile: blocks credentials and US SSN personal data formats",
    definition: {
      input: {action: "block", detectors: {secret: {}}, custom_rules: [{id: "us_ssn", match: {regex: "\\b\\d{3}-\\d{2}-\\d{4}\\b"}}]},
      output: {action: "observe", detectors: {secret: {}}}}}')"

# Application code: send the user's message and handle a guardrail block.
ask_support_bot() {
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$1" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
}

echo "--- Case 1: Standard Customer Query ---"
PROMPT="I need help resetting my account password for user@example.com."
echo "User: \"$PROMPT\""
ask_support_bot "$PROMPT"
if [ "$HTTP_CODE" = "200" ]; then
  echo "Assistant: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")"
else
  echo "Unexpected error (HTTP $HTTP_CODE):"; describe_block
fi

echo ""
echo "--- Case 2: Query Containing Sensitive Personal Data ---"
PROMPT="My claim reference number is associated with SSN 123-45-6789. Can you update my record?"
echo "User: \"$PROMPT\""
ask_support_bot "$PROMPT"
if [ "$HTTP_CODE" = "403" ]; then
  echo ""
  echo "[Gateway guardrail block: HTTP 403]"
  describe_block
  echo ""
  echo "Application fallback response to the end user:"
  echo "  \"Notice: For your security, please do not include Social Security numbers or other sensitive identifiers in support requests.\""
else
  echo "Processed unexpectedly (HTTP $HTTP_CODE)."
fi

echo ""
echo "Evidence in the Cloptima Console:"
echo "  - Audit trail: $CONSOLE_AUDIT"
echo "  - Policies: $CONSOLE_POLICIES"
