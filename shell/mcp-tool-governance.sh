#!/usr/bin/env bash
# Enterprise agent with governed MCP tools. The agent calls tools through Cloptima's MCP
# governance layer, and the application handles tool servers and tools that policy does not allow.
#
# 1. Governance setup: register tool servers and bind a policy that allows one of them. On plans
#    with approval workflows, a newly registered server is created `disabled` with a
#    `pending_approval_id` until it is reviewed. On other plans it is created `active`.
# 2. Case 1: an allowed tool on an approved server is admitted.
# 3. Case 2: an unregistered server is blocked with HTTP 403.
# 4. Case 3: a tool the server does not allow is blocked with HTTP 403.
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (registers tool servers and creates the policy and key).
# Run standalone: ./mcp-tool-governance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
SUFFIX="$(run_suffix)"

echo "=== Enterprise Agent: MCP Tool Governance ==="
echo ""

# Governance setup (admin): platform admins normally register tool servers once in the Console
# or through the API.
echo "Registering a new tool server..."
PENDING_SERVER=$(admin_api POST /v1/llm/tool-servers "" "$(jq -n --arg name "mcp-pending-$SUFFIX" '{
  name: $name, server_type: "mcp", server_url: "https://mcp.example.com/v1", status: "active",
  allowed_tool_names: ["search", "lookup"]}')")
PENDING_APPROVAL_ID=$(jq -r '.pending_approval_id // empty' <<<"$PENDING_SERVER")
if [ -n "$PENDING_APPROVAL_ID" ]; then
  echo "  $(jq -r '.name' <<<"$PENDING_SERVER"): status \"$(jq -r '.status' <<<"$PENDING_SERVER")\" until an admin approves the registration."
  echo "  Review queued as approval $PENDING_APPROVAL_ID ($CONSOLE_AUDIT)."
else
  echo "  $(jq -r '.name' <<<"$PENDING_SERVER"): status \"$(jq -r '.status' <<<"$PENDING_SERVER")\" (this plan has no registration review step)."
fi

echo ""
echo "Registering a reviewed tool server with apply_immediately: true..."
SERVER_LABEL="mcp-github-$SUFFIX"
ACTIVE_SERVER=$(admin_api POST /v1/llm/tool-servers "" "$(jq -n --arg name "$SERVER_LABEL" '{
  name: $name, server_type: "mcp", server_url: "https://mcp.github.example/v1", status: "active",
  allowed_tool_names: ["create_issue", "list_issues"], apply_immediately: true}')")
echo "  $(jq -r '.name' <<<"$ACTIVE_SERVER"): status \"$(jq -r '.status' <<<"$ACTIVE_SERVER")\""

provision_app "mcp-agent-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --arg server "$SERVER_LABEL" '{
  name: "mcp-agent-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model],
  allowed_tool_servers: [$server]}')"

# Application code. Responses API request that attaches an MCP server; prints whether the gateway
# blocked it and why.
call_with_mcp_server() {
  local server_label="$1" tool_name="$2"
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/responses" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg server "$server_label" --arg tool "$tool_name" '{
      model: $model, input: "Run the requested maintenance task.",
      tools: [{type: "mcp", server_label: $server, allowed_tools: [$tool], require_approval: "always"}]}')")
  if [ "$HTTP_CODE" != "403" ] && { [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; }; then
    echo "Example failed: request returned unexpected HTTP $HTTP_CODE" >&2
    describe_block >&2
    exit 1
  fi
}

echo ""
echo "--- Case 1: Allowed Tool on an Approved Server ---"
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg server "$SERVER_LABEL" '{
    model: $model,
    messages: [{role: "user", content: "Open an issue titled \"Update documentation\" on GitHub."}],
    tools: [{type: "function", function: {
      name: "create_issue",
      description: "Create a new issue on a GitHub repository",
      parameters: {type: "object", properties: {title: {type: "string", description: "The issue title"}, body: {type: "string", description: "The issue description"}}, required: ["title"]},
      mcp_server: $server}}]}')")
echo "Gateway status: HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
  jq -r '.choices[0].message | if .tool_calls then "Model selected tool: \(.tool_calls[0].function.name)(\(.tool_calls[0].function.arguments))" else "Model response: \(.content)" end' "$RESP_BODY_FILE"
else
  describe_block
  exit 1
fi

echo ""
echo "--- Case 2: Unregistered Tool Server ---"
call_with_mcp_server "unregistered-server" "create_issue"
if [ "$HTTP_CODE" = "403" ]; then
  echo "Blocked before inference (HTTP 403)."; describe_block
else
  echo "Admitted unexpectedly (HTTP $HTTP_CODE)."
fi

echo ""
echo "--- Case 3: Tool Not on the Server Allowlist ---"
call_with_mcp_server "$SERVER_LABEL" "drop_database"
if [ "$HTTP_CODE" = "403" ]; then
  echo "Blocked before inference (HTTP 403)."; describe_block
  echo "Application action: abort the tool call and return control to the user."
else
  echo "Admitted unexpectedly (HTTP $HTTP_CODE)."
fi

echo ""
echo "Evidence in the Cloptima Console:"
echo "  - Audit trail: $CONSOLE_AUDIT"
echo "  - Registered tool servers & policies: $CONSOLE_POLICIES"
