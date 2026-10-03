#!/usr/bin/env bash
# Bring your own key (BYOK): route a managed-gateway call through your own provider credential so
# Cloptima's governance, attribution, and telemetry apply, while inference is billed to your own
# provider account instead of Cloptima's managed-credits wallet.
#
# Provider credential, one of:
#   CLOPTIMA_PROVIDER_CREDENTIAL_ID - a credential already registered in the Console
#   PROVIDER_API_KEY                - your OpenAI-compatible key; this script registers it (needs the admin key)
#
# Auth: CLOPTIMA_VIRTUAL_KEY + CLOPTIMA_PROVIDER_CREDENTIAL_ID (runs only the application code), or
# CLOPTIMA_AI_ADMIN_KEY (also registers the credential, and creates the policy and key).
# Run standalone: ./byok.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

BYOK_MODEL="openai/gpt-4o-mini"

echo "=== Bring-Your-Own-Key (BYOK): Enterprise Credential Routing ==="
echo ""

if [ -n "${CLOPTIMA_PROVIDER_CREDENTIAL_ID:-}" ]; then
  CREDENTIAL_ID="$CLOPTIMA_PROVIDER_CREDENTIAL_ID"
  echo "Using registered provider credential ID: $CREDENTIAL_ID"
elif [ -n "${PROVIDER_API_KEY:-}" ]; then
  echo "Registering your provider credential (BYOK)..."
  CREDENTIAL=$(graphql 'mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
    createLLMProviderCredential(input: $input) { id provider displayName }
  }' "$(jq -n --arg apiKey "$PROVIDER_API_KEY" --arg displayName "byok-openai-$(run_suffix)" \
    '{input: {provider: "openai", displayName: $displayName, apiKey: $apiKey}}')")
  CREDENTIAL_ID=$(jq -r '.createLLMProviderCredential.id' <<<"$CREDENTIAL")
  echo "Registered credential: $CREDENTIAL_ID"
else
  echo "Set PROVIDER_API_KEY (or CLOPTIMA_PROVIDER_CREDENTIAL_ID) in .env (see .env.example)." >&2
  exit 1
fi
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "byok-demo" "$(jq -n --arg model "$BYOK_MODEL" '{
  name: "byok-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["openai"], allowedModels: [$model]}')"

# Application code: the credential header routes the call through your own provider account.
echo "Sending a query through the Cloptima Gateway under the BYOK credential..."
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -H "x-cloptima-provider-credential-id: $CREDENTIAL_ID" \
  -d "$(jq -n --arg model "$BYOK_MODEL" '{
    model: $model, temperature: 0.7,
    messages: [
      {role: "system", content: "You are an enterprise AI architect."},
      {role: "user", content: "Summarize the advantage of Bring-Your-Own-Key (BYOK) architecture for enterprise compliance in two sentences."}]}')")
if [ "$HTTP_CODE" = "200" ]; then
  echo ""
  jq -r '"--- Model Response ---\n\(.choices[0].message.content)\n\n--- BYOK Execution Telemetry ---\nModel: \(.model)\nTokens: prompt=\(.usage.prompt_tokens), completion=\(.usage.completion_tokens), total=\(.usage.total_tokens)"' "$RESP_BODY_FILE"
  echo "Billed to: your provider account (via credential $CREDENTIAL_ID)"
else
  echo "BYOK request failed (HTTP $HTTP_CODE):"; describe_block
fi

echo ""
echo "Review credential usage and logs in the Cloptima Console:"
echo "  - Credentials: $CONSOLE_CREDENTIALS"
echo "  - Audit: $CONSOLE_AUDIT"
echo "  - Spend Explorer: $CONSOLE_SPEND"
