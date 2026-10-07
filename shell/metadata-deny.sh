#!/usr/bin/env bash
# FinOps attribution: a policy that requires team_id, app_id, and environment metadata.
#
# The script mints a virtual key deliberately WITHOUT team/app/environment and binds it by
# principalId, the only way to produce a genuine missing-attribution block: a key with baked-in
# team/app/environment is trusted as an attribution fallback when headers are absent. Calling with
# no headers is refused with HTTP 400. Calling with the x-cloptima-team, x-cloptima-app, and
# x-cloptima-environment headers is admitted and attributed.
#
# Auth: CLOPTIMA_AI_ADMIN_KEY creates the policy and an unscoped key. CLOPTIMA_VIRTUAL_KEY must be
# an unscoped key bound to a policy that requires team_id, app_id, and environment; a key with team
# and app baked in supplies its own attribution, so Case 1 would not be refused.
# Run standalone: ./metadata-deny.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== FinOps Attribution: Enforcing Team & Application Tags ==="
echo ""

if [ -n "$CLOPTIMA_VIRTUAL_KEY" ]; then
  echo "Using CLOPTIMA_VIRTUAL_KEY. It should be an unscoped key bound to a policy requiring attribution metadata."
  echo ""
  ACCESS_TOKEN="$CLOPTIMA_VIRTUAL_KEY"
else
  require_admin_key
  SUFFIX="$(run_suffix)"
  echo "Configuring a policy that requires team_id/app_id/environment metadata..."
  POLICY=$(create_policy "$(jq -n --arg name "attribution-policy-$SUFFIX" --arg model "$MODEL_DEFAULT" '{
    name: $name, mode: "enforce", budgetMode: "hard",
    allowedProviders: ["vertex_ai"], allowedModels: [$model],
    metadata: {required_metadata_keys: ["team_id", "app_id", "environment"]}}')")
  KEY=$(create_virtual_key "$(jq -n --arg name "vk-attribution-$SUFFIX" '{name: $name}')")
  KEY_ID=$(jq -r '.id' <<<"$KEY")
  ACCESS_TOKEN=$(jq -r '.accessToken' <<<"$KEY")
  create_binding "$(jq -n --arg policyId "$(jq -r '.id' <<<"$POLICY")" --arg principalId "$KEY_ID" \
    '{policyId: $policyId, principalId: $principalId, actorType: "service", priority: 5, acknowledgeOverlap: true}')" >/dev/null
  echo "Minted unscoped key $KEY_ID and bound it."
  echo ""
fi

# Application code: the same request with and without attribution headers.
echo "--- Case 1: Unattributed Request (Missing Headers) ---"
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" '{model: $model, messages: [{role: "user", content: "Execute unallocated query."}]}')")
if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "403" ]; then
  echo "Gateway attribution enforcement (HTTP $HTTP_CODE):"
  describe_block
  echo ""
  echo "Application action: request rejected because team and application cost centers were not provided."
else
  echo "Admitted unexpectedly (HTTP $HTTP_CODE)."
fi

echo ""
echo "--- Case 2: Attributed Request (With Cost Center Headers) ---"
TEAM="Payment-Services"
APP="checkout-fraud-detection"
echo "Injecting headers: x-cloptima-team=\"$TEAM\", x-cloptima-app=\"$APP\", x-cloptima-environment=\"production\""
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -H "x-cloptima-team: $TEAM" \
  -H "x-cloptima-app: $APP" \
  -H "x-cloptima-environment: production" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" '{model: $model, messages: [{role: "user", content: "Explain fraud detection scoring briefly."}]}')")
if [ "$HTTP_CODE" = "200" ]; then
  echo "Assistant: $(jq -r '.choices[0].message.content' "$RESP_BODY_FILE")"
  echo "Request admitted and attributed to team \"$TEAM\" and app \"$APP\"."
else
  echo "Attributed call failed (HTTP $HTTP_CODE):"; describe_block
fi

echo ""
echo "Review attributed spend in the Cloptima Console:"
echo "  - Spend Explorer: $CONSOLE_SPEND"
echo "  - Audit: $CONSOLE_AUDIT"
