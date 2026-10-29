#!/usr/bin/env bash
# Customer support assistant with personal data (PII) protection: a guardrail profile that
# protects personal data, and how the application handles a guardrail block.
#
# 1. Governance setup: a guardrail profile that redacts US personal data (the us_personal_data
#    template) and blocks employee IDs (a custom employee_id rule).
# 2. Case 1: a message with an email address and a phone number is answered. The model provider
#    sees placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of the values, and the
#    gateway restores the values in the response, so the application gets its own data back.
# 3. Case 2: a message with an employee ID is refused before it reaches the model (HTTP 403).
#    The application reads the block reason and returns a friendly message.
#
# Prerequisite: custom rules and every template except secrets need the
# llm_guardrail_enterprise entitlement.
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
CUSTOMER_EMAIL="jane.doe@example.com"
CUSTOMER_PHONE="415-555-0142"

echo "=== Customer Support Assistant: PII & Guardrails ==="
echo ""

# Governance setup: a guardrail profile attached to the policy this application runs under.
# Platform admins normally create these once in the Console, Terraform, or CI. Skipped when
# CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
# The template entry takes the latest version; add "version" to pin one. The employee_id rule
# matches a value such as "Employee ID: E482913".
get_access "support-bot-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "support-guardrail-policy", mode: "enforce", budget_mode: "hard", fail_mode: "fail_closed",
  allowed_providers: ["vertex_ai"], allowed_models: [$model]}')" \
  "$(jq -n '{
    name: "support-guardrail-profile",
    description: "Customer support: redact US personal data, block employee IDs",
    definition: {
      protect: [
        {template: "us_personal_data", action: "redact"},
        {rule: "employee_id", match: {label: "(?i:employee id)", value: "E\\d{6}"}, action: "block"}]}}')"

# Application code: send the user's message and handle a guardrail block.
ask_support_bot() {
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$1" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
}

# Case 1: personal data is redacted for the provider and restored for the application.
echo "--- Case 1: Query Containing an Email Address and Phone Number ---"
PROMPT="I can't sign in. My account email is $CUSTOMER_EMAIL and my phone is $CUSTOMER_PHONE. Repeat my contact details back to me, then tell me the next step."
echo "User: \"$PROMPT\""
ask_support_bot "$PROMPT"
if [ "$HTTP_CODE" = "200" ]; then
  REPLY=$(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")
  echo "Assistant: $REPLY"
  echo ""
  echo "The model provider received placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of"
  echo "the email address and phone number. The gateway restored the values in the response."
  case "$REPLY" in
    *"$CUSTOMER_EMAIL"*|*"$CUSTOMER_PHONE"*) echo "✓ The answer shows the customer's own contact details." ;;
  esac
  echo ""
else
  echo "Unexpected error (HTTP $HTTP_CODE):"; describe_block
  echo ""
fi

# Case 2: a block rule refuses the request before it reaches the model.
echo "--- Case 2: Query Containing an Employee ID ---"
PROMPT="Please apply my staff discount to order 1042. My Employee ID: E482913."
echo "User: \"$PROMPT\""
ask_support_bot "$PROMPT"
if [ "$HTTP_CODE" = "403" ]; then
  # The gateway's block body: {"error": "<message>", "reason": "gateway_guardrail_blocked", "violations": [...]}.
  # A custom rule's violation is custom_<rule id>, here custom_employee_id.
  echo ""
  echo "[Gateway Guardrail Block: HTTP 403]"
  describe_block
  echo ""
  echo "Application Fallback Response to End User:"
  echo "  \"Notice: For your security, please do not include employee IDs in support requests. Please submit your request without internal identifiers.\""
  echo ""
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "Assistant: (Processed unexpectedly, HTTP $HTTP_CODE)"
  echo ""
else
  echo "Example failed: request returned unexpected HTTP $HTTP_CODE" >&2
  describe_block >&2
  exit 1
fi

echo "Evidence in Cloptima Console:"
echo "  - Guardrail profiles: $CONSOLE_GUARDRAILS"
echo "  - Audit trail: $CONSOLE_AUDIT"
