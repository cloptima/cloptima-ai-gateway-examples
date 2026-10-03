#!/usr/bin/env bash
# MCP tool governance: registration, approval, allowed tools, and definition review.
#
# The first registration waits for review. A qualifying admin then creates an
# immediately active server to demonstrate tool-definition review. The final
# checks use provider-called MCP tools, whose access is checked before inference.
# Run standalone: ./mcp-tool-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
SUFFIX="$(run_suffix)"
APP_ID="mcp-tool-governance-$SUFFIX"
SERVER_LABEL="example-mcp-server-$SUFFIX"

# call_responses_api <access_token> <require_approval> <server_label> <tool_name> <label>
# and prints the outcome; full response body is left in $RESP_BODY_FILE.
call_responses_api() {
  local access_token="$1" require_approval="$2" server_label="$3" tool_name="$4" label="$5"
  local body
  body=$(jq -n --arg model "$MODEL_DEFAULT" --arg input "Test call with require_approval: $require_approval." \
    --arg serverLabel "$server_label" --arg toolName "$tool_name" --arg requireApproval "$require_approval" \
    '{model: $model, input: $input, tools: [{type: "mcp", server_label: $serverLabel, allowed_tools: [$toolName], require_approval: $requireApproval}]}')
  LAST_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/responses" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$body")
  LAST_OUTCOME=$(outcome_for_status "$LAST_HTTP_CODE")
  echo "  [$LAST_OUTCOME] $label (http $LAST_HTTP_CODE)"
}

call_chat_completions() {
  local access_token="$1" tool_def="$2" prompt="$3" body
  body=$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$prompt" --argjson tool "$tool_def" \
    '{model: $model, messages: [{role: "user", content: $prompt}], tools: [$tool]}')
  LAST_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$body")
}

query_tool_definitions() {
  local server_id="$1"
  graphql 'query GetToolDefs($serverId: ID) {
    llmGatewayToolDefinitions(serverId: $serverId) {
      definitions { toolName definitionSha256 status }
    }
  }' "$(jq -n --arg serverId "$server_id" '{serverId: $serverId}')"
}

wait_for_tool_definition() {
  local server_id="$1" status="$2" attempt
  for ((attempt=0; attempt<16; attempt++)); do
    TOOL_DEFINITIONS=$(query_tool_definitions "$server_id")
    if jq -e --arg status "$status" '.llmGatewayToolDefinitions.definitions | any(.toolName == "create_issue" and .status == $status)' <<<"$TOOL_DEFINITIONS" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 1. Registration and approval
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
  echo "  This script leaves the approval pending. An eligible owner or admin can review it in the"
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
call_responses_api "$ACCESS_TOKEN" "always" "$SERVER_LABEL" "search" "always-call"
jq '.' "$RESP_BODY_FILE"
confirm_blocked "always-call" 403
ALWAYS_VIOLATIONS=$(jq -c '.violations // []' "$RESP_BODY_FILE")

echo ""
echo "Calling again with require_approval: 'never'..."
call_responses_api "$ACCESS_TOKEN" "never" "$SERVER_LABEL" "search" "never-call"
jq '.' "$RESP_BODY_FILE"
confirm_blocked "never-call" 403
NEVER_VIOLATIONS=$(jq -c '.violations // []' "$RESP_BODY_FILE")

confirm_equals "$(echo "$ALWAYS_VIOLATIONS" | jq 'contains(["tool_server_disabled"])')" "true" "'always' should be blocked by tool_server_disabled"
confirm_equals "$(echo "$NEVER_VIOLATIONS" | jq 'contains(["tool_server_disabled"])')" "true" "'never' should carry tool_server_disabled too"
confirm_equals "$(echo "$NEVER_VIOLATIONS" | jq 'contains(["tool_server_auto_approval_disabled"])')" "true" "'never' should carry tool_server_auto_approval_disabled"
confirm_equals "$(echo "$ALWAYS_VIOLATIONS" | jq 'contains(["tool_server_auto_approval_disabled"])')" "false" "'always' should not carry tool_server_auto_approval_disabled"

echo "Confirmed: pending servers are blocked; require_approval: 'never' adds its own violation."

# 2. Active server and definition review
echo ""
echo "Registering an active tool server with applyImmediately: true..."
ACTIVE_SERVER_LABEL="example-mcp-active-$SUFFIX"
TOOL_SERVER_2=$(graphql \
  'mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
    createLLMGatewayToolServer(input: $input) { id name status }
  }' \
  "$(jq -n --arg name "$ACTIVE_SERVER_LABEL" \
    '{input: {name: $name, serverType: "mcp", serverUrl: "https://mcp.github.example/v1", status: "active", allowedToolNames: ["create_issue", "list_issues"], applyImmediately: true}}')")
TOOL_SERVER_2=$(echo "$TOOL_SERVER_2" | jq -c '.createLLMGatewayToolServer')
echo "  tool server $(echo "$TOOL_SERVER_2" | jq -r '.id') - status: $(echo "$TOOL_SERVER_2" | jq -r '.status')"
TS2_STATUS=$(echo "$TOOL_SERVER_2" | jq -r '.status // empty')
confirm_equals "$TS2_STATUS" "active" "applyImmediately: true should register the tool server as 'active'"
ACTIVE_SERVER_ID=$(jq -r '.id' <<<"$TOOL_SERVER_2")

echo ""
echo "Creating a policy for the active server..."
ACTIVE_POLICY=$(create_policy "$(jq -n --arg name "mcp-active-policy-$SUFFIX" --arg model "$MODEL_DEFAULT" --arg serverLabel "$ACTIVE_SERVER_LABEL" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], allowedToolServers: [$serverLabel]}')")
ACTIVE_POLICY_ID=$(jq -r '.id' <<<"$ACTIVE_POLICY")
ACTIVE_APP_ID="$APP_ID-active"
ACTIVE_KEY=$(create_virtual_key "$(jq -n --arg name "vk-mcp-active-$SUFFIX" --arg appId "$ACTIVE_APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACTIVE_TOKEN=$(jq -r '.accessToken' <<<"$ACTIVE_KEY")
create_binding "$(jq -n --arg policyId "$ACTIVE_POLICY_ID" --arg appId "$ACTIVE_APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null

TOOL_V1=$(jq -n --arg server "$ACTIVE_SERVER_LABEL" '{type: "function", function: {
  name: "create_issue", description: "Create a new issue on GitHub repository",
  parameters: {type: "object", properties: {title: {type: "string"}}, required: ["title"]}, mcp_server: $server
}}')
call_chat_completions "$ACTIVE_TOKEN" "$TOOL_V1" "Please create an issue titled Bug in login"
confirm_equals "$LAST_HTTP_CODE" "200" "First tool-definition request should succeed"
wait_for_tool_definition "$ACTIVE_SERVER_ID" "approved"
APPROVED_V1=$(jq -c '.llmGatewayToolDefinitions.definitions[] | select(.toolName == "create_issue" and .status == "approved")' <<<"$TOOL_DEFINITIONS" | head -1)
OLD_SHA=$(jq -r '.definitionSha256' <<<"$APPROVED_V1")
echo "Confirmed: first tool definition registered as the approved baseline."

TOOL_V2=$(jq -n --arg server "$ACTIVE_SERVER_LABEL" '{type: "function", function: {
  name: "create_issue", description: "Create a new issue on GitHub repository with priority tags",
  parameters: {type: "object", properties: {title: {type: "string"}, priority: {type: "string", enum: ["low", "medium", "high", "critical"]}}, required: ["title", "priority"]},
  mcp_server: $server
}}')
call_chat_completions "$ACTIVE_TOKEN" "$TOOL_V2" "Create urgent issue with priority high"
confirm_equals "$LAST_HTTP_CODE" "200" "Changed tool-definition request should succeed"
wait_for_tool_definition "$ACTIVE_SERVER_ID" "pending"
PENDING_V2=$(jq -c '.llmGatewayToolDefinitions.definitions[] | select(.toolName == "create_issue" and .status == "pending")' <<<"$TOOL_DEFINITIONS" | head -1)
NEW_SHA=$(jq -r '.definitionSha256' <<<"$PENDING_V2")
echo "Confirmed: changed definition recorded as pending review."

REVIEWED=$(graphql 'mutation ReviewToolDef($input: LLMGatewayToolDefinitionReviewInput!) {
  reviewLLMGatewayToolDefinition(input: $input) { status }
}' "$(jq -n --arg serverId "$ACTIVE_SERVER_ID" --arg sha "$NEW_SHA" \
  '{input: {serverId: $serverId, toolName: "create_issue", definitionSha256: $sha, decision: "approve"}}')")
confirm_equals "$(jq -r '.reviewLLMGatewayToolDefinition.status' <<<"$REVIEWED")" "approved" "Reviewed definition should be approved"
TOOL_DEFINITIONS=$(query_tool_definitions "$ACTIVE_SERVER_ID")
confirm_equals "$(jq -r --arg sha "$OLD_SHA" '.llmGatewayToolDefinitions.definitions[] | select(.definitionSha256 == $sha) | .status' <<<"$TOOL_DEFINITIONS")" "superseded" "Prior definition should be superseded"
echo "Confirmed: reviewed definition approved and prior version superseded."

# 3. Provider-called MCP checks
call_responses_api "$ACTIVE_TOKEN" "always" "unregistered-server" "create_issue" "unknown-server"
confirm_blocked "unknown-server" 403
confirm_equals "$(jq -r '(.violations // []) | index("tool_server_unknown") != null' "$RESP_BODY_FILE")" "true" "Unknown-server violation"

call_responses_api "$ACTIVE_TOKEN" "always" "$ACTIVE_SERVER_LABEL" "drop_database" "disallowed-tool"
confirm_blocked "disallowed-tool" 403
confirm_equals "$(jq -r '(.violations // []) | index("tool_server_tool_not_allowed") != null' "$RESP_BODY_FILE")" "true" "Disallowed-tool violation"
echo "Confirmed: unknown servers and disallowed MCP tools are blocked before inference."
echo "Evidence: Audit tab ($CONSOLE_AUDIT); Policies tab ($CONSOLE_POLICIES)."
