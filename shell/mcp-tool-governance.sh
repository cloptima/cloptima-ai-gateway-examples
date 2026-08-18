#!/usr/bin/env bash
# MCP / tool-server governance: register a tool server, allow it (and only
# it) on a policy, then exercise the OpenAI Responses API's remote-MCP-tool
# path through the managed proxy.
#
# A newly registered tool server is always 'disabled', even if the request
# asks for status: 'active' - registration overrides it and auto-queues an
# mcp_tool_server_registration approval in the same generic
# governance queue as semantic-cache-enforce.sh's auto-queued
# semantic_cache_enforce entry. Reviewing that approval is the same
# second-identity step this repo never scripts (see approval-workflow.sh),
# so both calls below are expected to be blocked by tool_server_disabled -
# this example isn't demonstrating an allowed call, it's demonstrating the
# governance gate and that require_approval: 'never' is enforced as its own,
# separate rule on top of it: the 'never' call's violations list carries an
# additional tool_server_auto_approval_disabled entry the 'always' call
# doesn't get, proving that rule holds independently of (and would still
# apply once) the tool server is reviewed and made active.
#
# At the end, a second tool server is registered with applyImmediately: true
# to show the alternative: since this key already qualifies to review this
# itself, that one activates right away instead of starting 'disabled'.
# Run standalone: ./mcp-tool-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"
APP_ID="mcp-tool-governance-$SUFFIX"
SERVER_LABEL="example-mcp-server-$SUFFIX"

# call_responses_api <access_token> <require_approval> -> sets LAST_HTTP_CODE
# and prints the outcome; full response body is left in $RESP_BODY_FILE.
call_responses_api() {
  local access_token="$1" require_approval="$2" label="$3"
  local body
  body=$(jq -n --arg model "$MODEL_DEFAULT" --arg input "Test call with require_approval: $require_approval." \
    --arg serverLabel "$SERVER_LABEL" --arg requireApproval "$require_approval" \
    '{model: $model, input: $input, tools: [{type: "mcp", server_label: $serverLabel, allowed_tools: ["search"], require_approval: $requireApproval}]}')
  LAST_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/responses" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$body")
  LAST_OUTCOME=$(outcome_for_status "$LAST_HTTP_CODE")
  echo "  [$LAST_OUTCOME] $label (http $LAST_HTTP_CODE)"
}

echo "Registering a tool server (label $SERVER_LABEL, requesting status: active)..."
TOOL_SERVER=$(graphql \
  'mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
    createLLMGatewayToolServer(input: $input) { id name serverType status allowedToolNames }
  }' \
  "$(jq -n --arg name "$SERVER_LABEL" \
    '{input: {name: $name, serverType: "mcp", serverUrl: "https://example.com/mcp", status: "active", allowedToolNames: ["search", "lookup"]}}')")
TOOL_SERVER=$(echo "$TOOL_SERVER" | jq -c '.createLLMGatewayToolServer')
TOOL_SERVER_ID=$(echo "$TOOL_SERVER" | jq -r '.id')
echo "  tool server $TOOL_SERVER_ID ($(echo "$TOOL_SERVER" | jq -r '.name')) - actual status: $(echo "$TOOL_SERVER" | jq -r '.status') (forced to 'disabled' pending review, regardless of the 'active' requested above)"

echo ""
echo "Checking the generic governance queue for the auto-queued mcp_tool_server_registration approval..."
PENDING=$(list_llm_gateway_approvals "pending" 50)
AUTO_QUEUED=$(echo "$PENDING" | jq -c --arg toolServerId "$TOOL_SERVER_ID" '.[] | select(.approvalType == "mcp_tool_server_registration" and .targetId == $toolServerId)')
if [ -n "$AUTO_QUEUED" ]; then
  echo "  pending: $AUTO_QUEUED"
  echo "  This is the one step this script does NOT do: reviewing it requires a second privileged identity in the"
  echo "  console's Audit tab ($CONSOLE_AUDIT). Until reviewed, this tool server stays 'disabled' and any call"
  echo "  through it is blocked."
else
  echo "  no matching pending entry found (it may already have been reviewed on a prior run of this example)."
fi

echo ""
echo "Creating a policy that allows only this tool server..."
POLICY=$(create_policy "$(jq -n --arg name "mcp-tool-governance-$SUFFIX" --arg model "$MODEL_DEFAULT" --arg serverLabel "$SERVER_LABEL" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], allowedToolServers: [$serverLabel]}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-mcp-tool-governance-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound."
echo ""

echo "Dry-run simulating whether this tool server/tool would be allowed under the policy..."
# Must match the binding above (team + app + environment) so the simulation
# resolves against the same policy the real calls below will run under.
SIMULATION=$(graphql \
  'query Simulate($input: LLMGatewayToolPolicySimulationInput!) {
    llmGatewayToolPolicySimulation(input: $input) {
      allowed reason violations
      policy { id name }
      toolServer { id name }
    }
  }' \
  "$(jq -n --arg serverLabel "$SERVER_LABEL" --arg appId "$APP_ID" \
    '{input: {toolServerName: $serverLabel, toolName: "search", teamId: "Platform AI", appId: $appId, environment: "dev"}}')")
echo "  simulation: $(echo "$SIMULATION" | jq -c '.llmGatewayToolPolicySimulation')"

echo ""
echo "Calling the Responses API with require_approval: 'always'..."
call_responses_api "$ACCESS_TOKEN" "always" "always-call"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Calling again with require_approval: 'never'..."
call_responses_api "$ACCESS_TOKEN" "never" "never-call"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Expected: both calls are blocked (403) because the tool server above is still 'disabled' pending review -"
echo "'always' is blocked by tool_server_disabled alone. 'never' carries that SAME violation plus an additional"
echo "tool_server_auto_approval_disabled entry the 'always' call does not get - proving the never-auto-approve"
echo "rule is enforced as its own, independent check that would still apply even after this tool server is"
echo "reviewed and made active."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$APP_ID\" for both records and the pending tool-server-registration approval; Policies tab ($CONSOLE_POLICIES) shows the tool server registration and allowedToolServers config."

echo ""
echo "Registering a second tool server, this time with applyImmediately: true..."
TOOL_SERVER_2=$(graphql \
  'mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
    createLLMGatewayToolServer(input: $input) { id name status }
  }' \
  "$(jq -n --arg name "example-mcp-server-immediate-$SUFFIX" \
    '{input: {name: $name, serverType: "mcp", serverUrl: "https://example.com/mcp", status: "active", allowedToolNames: ["search", "lookup"], applyImmediately: true}}')")
TOOL_SERVER_2=$(echo "$TOOL_SERVER_2" | jq -c '.createLLMGatewayToolServer')
echo "  tool server $(echo "$TOOL_SERVER_2" | jq -r '.id') - status: $(echo "$TOOL_SERVER_2" | jq -r '.status')"
echo "Expected: status 'active' right away - applyImmediately: true meant this registration was approved and"
echo "activated in this same call, with no separate review step and no tool_server_disabled block."
