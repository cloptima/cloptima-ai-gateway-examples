"""MCP tool governance: registration, approval, allowed tools, and definition review.

The first registration waits for review. A qualifying admin then creates an
immediately active server to demonstrate tool-definition review. The final
checks use provider-called MCP tools, whose access is checked before inference.

Run standalone from python/:
    python -m examples.mcp_tool_governance
"""

import json
import time

import requests

from lib import config
from lib.confirm import confirm_blocked, confirm_equals
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql, list_llm_gateway_approvals
from lib.models import MODEL_DEFAULT


def call_responses_api(access_token: str, require_approval: str, server_label: str, allowed_tools=None) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/responses",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {access_token}",
        },
        json={
            "model": MODEL_DEFAULT,
            "input": f"Test call with require_approval: {require_approval}.",
            "tools": [{"type": "mcp", "server_label": server_label, "allowed_tools": allowed_tools or ["search"], "require_approval": require_approval}],
        },
        timeout=30,
    )
    body = response.json()
    outcome = "allowed" if response.status_code == 200 else ("blocked" if 400 <= response.status_code < 500 else "error")
    return {"outcome": outcome, "status": response.status_code, "body": body}


def call_chat_completions(access_token: str, tool: dict, prompt: str) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/chat/completions",
        headers={"content-type": "application/json", "user-agent": config.USER_AGENT, "authorization": f"Bearer {access_token}"},
        json={"model": MODEL_DEFAULT, "messages": [{"role": "user", "content": prompt}], "tools": [tool]},
        timeout=30,
    )
    return {"status": response.status_code, "body": response.json()}


def query_tool_definitions(server_id: str) -> dict:
    data = graphql(
        """query GetToolDefs($serverId: ID) {
          llmGatewayToolDefinitions(serverId: $serverId) {
            definitions { toolName definitionSha256 status }
          }
        }""",
        {"serverId": server_id},
    )
    return data["llmGatewayToolDefinitions"]


def wait_for_tool_definition(server_id: str, predicate, timeout_seconds: int = 15) -> dict:
    deadline = time.monotonic() + timeout_seconds
    while True:
        result = query_tool_definitions(server_id)
        if predicate(result) or time.monotonic() >= deadline:
            return result
        time.sleep(1)


def review_tool_definition(server_id: str, tool_name: str, definition_sha256: str) -> dict:
    data = graphql(
        """mutation ReviewToolDef($input: LLMGatewayToolDefinitionReviewInput!) {
          reviewLLMGatewayToolDefinition(input: $input) { status }
        }""",
        {"input": {"serverId": server_id, "toolName": tool_name, "definitionSha256": definition_sha256, "decision": "approve"}},
    )
    return data["reviewLLMGatewayToolDefinition"]


def main():
    suffix = config.run_suffix()
    app_id = f"mcp-tool-governance-{suffix}"
    server_label = f"example-mcp-server-{suffix}"

    print(f"Registering a tool server (label {server_label}, requesting status: active)...")
    tool_server_data = graphql(
        """mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
          createLLMGatewayToolServer(input: $input) { id name serverType status allowedToolNames }
        }""",
        {"input": {
            "name": server_label,
            "serverType": "mcp",
            "serverUrl": "https://example.com/mcp",
            "status": "active",
            "allowedToolNames": ["search", "lookup"],
        }},
    )
    tool_server = tool_server_data["createLLMGatewayToolServer"]
    print(f"  tool server {tool_server['id']} ({tool_server['name']}) - actual status: {tool_server['status']} (forced to 'disabled' pending review, regardless of the 'active' requested above)")

    print("\nChecking the generic governance queue for the auto-queued mcp_tool_server_registration approval...")
    pending = list_llm_gateway_approvals(status="pending", limit=50)
    auto_queued = next((a for a in pending if a["approvalType"] == "mcp_tool_server_registration" and a["targetId"] == tool_server["id"]), None)
    if auto_queued:
        print(f"  pending: {json.dumps(auto_queued)}")
        print(
            "  This script leaves the approval pending. An eligible owner or admin can review it in the "
            f"console's Audit tab ({config.CONSOLE['audit']}). Until reviewed, this tool server stays 'disabled' and any call "
            "through it is blocked."
        )
    else:
        print("  no matching pending entry found (it may already have been reviewed on a prior run of this example).")

    print("\nCreating a policy that allows only this tool server...")
    policy = create_policy({
        "name": f"mcp-tool-governance-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "allowedToolServers": [server_label],
    })
    key = create_virtual_key({"name": f"vk-mcp-tool-governance-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.\n")

    print("Dry-run simulating whether this tool server/tool would be allowed under the policy...")
    simulation_data = graphql(
        """query Simulate($input: LLMGatewayToolPolicySimulationInput!) {
          llmGatewayToolPolicySimulation(input: $input) {
            allowed reason violations
            policy { id name }
            toolServer { id name }
          }
        }""",
        {"input": {
            "toolServerName": server_label,
            "toolName": "search",
            # Must match the binding above (team + app + environment) so the
            # simulation resolves against the same policy the real calls
            # below will run under.
            "teamId": "Platform AI",
            "appId": app_id,
            "environment": "dev",
        }},
    )
    print(f"  simulation: {json.dumps(simulation_data['llmGatewayToolPolicySimulation'])}")

    print("\nCalling the Responses API with require_approval: 'always'...")
    always_result = call_responses_api(key["accessToken"], "always", server_label)
    print(f"  [{always_result['outcome']}] {json.dumps(always_result)}")

    print("\nCalling again with require_approval: 'never'...")
    never_result = call_responses_api(key["accessToken"], "never", server_label)
    print(f"  [{never_result['outcome']}] {json.dumps(never_result)}")

    confirm_blocked(always_result, "tool server status 'disabled'", status=403)
    confirm_blocked(never_result, "tool server status 'disabled'", status=403)
    always_violations = (always_result.get("body") or {}).get("violations") or []
    never_violations = (never_result.get("body") or {}).get("violations") or []
    confirm_equals("tool_server_disabled" in always_violations, True, "'always' should be blocked by tool_server_disabled")
    confirm_equals("tool_server_disabled" in never_violations, True, "'never' should carry tool_server_disabled too")
    confirm_equals(
        ("tool_server_auto_approval_disabled" in never_violations) and ("tool_server_auto_approval_disabled" not in always_violations),
        True,
        "tool_server_auto_approval_disabled should apply to 'never' only",
    )
    print("Confirmed: pending servers are blocked; require_approval: 'never' adds its own violation.")

    # 2. Active server and definition review
    print("\nRegistering an active tool server with applyImmediately: true...")
    active_server_label = f"example-mcp-active-{suffix}"
    tool_server_2_data = graphql(
        """mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
          createLLMGatewayToolServer(input: $input) { id name status }
        }""",
        {"input": {
            "name": active_server_label,
            "serverType": "mcp",
            "serverUrl": "https://mcp.github.example/v1",
            "status": "active",
            "allowedToolNames": ["create_issue", "list_issues"],
            "applyImmediately": True,
        }},
    )
    tool_server_2 = tool_server_2_data["createLLMGatewayToolServer"]
    print(f"  tool server {tool_server_2['id']} - status: {tool_server_2['status']}")
    confirm_equals(tool_server_2.get("status"), "active", "applyImmediately: true should register the tool server as 'active'")
    print("\nCreating a policy for the active server...")
    active_policy = create_policy({
        "name": f"mcp-active-policy-{suffix}", "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "allowedToolServers": [active_server_label],
    })
    active_app_id = f"{app_id}-active"
    active_key = create_virtual_key({"name": f"vk-mcp-active-{suffix}", "teamId": "Platform AI", "appId": active_app_id, "environment": "dev"})
    create_binding({"policyId": active_policy["id"], "teamId": "Platform AI", "appId": active_app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})

    tool_v1 = {"type": "function", "function": {
        "name": "create_issue", "description": "Create a new issue on GitHub repository",
        "parameters": {"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]},
        "mcp_server": active_server_label,
    }}
    first_call = call_chat_completions(active_key["accessToken"], tool_v1, "Please create an issue titled Bug in login")
    confirm_equals(first_call["status"], 200, "First tool-definition request should succeed")
    definitions = wait_for_tool_definition(
        tool_server_2["id"], lambda result: any(d["toolName"] == "create_issue" and d["status"] == "approved" for d in result["definitions"]),
    )
    approved_v1 = next((d for d in definitions["definitions"] if d["toolName"] == "create_issue" and d["status"] == "approved"), None)
    confirm_equals(bool(approved_v1), True, "First definition should be registered as the approved baseline")
    print("Confirmed: first tool definition registered as the approved baseline.")

    tool_v2 = {"type": "function", "function": {
        "name": "create_issue", "description": "Create a new issue on GitHub repository with priority tags",
        "parameters": {"type": "object", "properties": {
            "title": {"type": "string"}, "priority": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
        }, "required": ["title", "priority"]},
        "mcp_server": active_server_label,
    }}
    second_call = call_chat_completions(active_key["accessToken"], tool_v2, "Create urgent issue with priority high")
    confirm_equals(second_call["status"], 200, "Changed tool-definition request should succeed")
    definitions = wait_for_tool_definition(
        tool_server_2["id"], lambda result: any(d["toolName"] == "create_issue" and d["status"] == "pending" for d in result["definitions"]),
    )
    pending_v2 = next((d for d in definitions["definitions"] if d["toolName"] == "create_issue" and d["status"] == "pending"), None)
    confirm_equals(bool(pending_v2), True, "Changed definition should await review")
    print("Confirmed: changed definition recorded as pending review.")

    reviewed = review_tool_definition(tool_server_2["id"], "create_issue", pending_v2["definitionSha256"])
    confirm_equals(reviewed["status"], "approved", "Reviewed definition should be approved")
    definitions = query_tool_definitions(tool_server_2["id"])["definitions"]
    confirm_equals(next((d["status"] for d in definitions if d["definitionSha256"] == approved_v1["definitionSha256"]), None), "superseded", "Prior definition should be superseded")
    print("Confirmed: reviewed definition approved and prior version superseded.")

    # 3. Provider-called MCP checks
    rogue = call_responses_api(active_key["accessToken"], "always", "unregistered-server", ["create_issue"])
    confirm_blocked(rogue, "unregistered MCP server", status=403)
    confirm_equals("tool_server_unknown" in rogue["body"].get("violations", []), True, "Unknown-server violation")

    disallowed = call_responses_api(active_key["accessToken"], "always", active_server_label, ["drop_database"])
    confirm_blocked(disallowed, "disallowed MCP tool", status=403)
    confirm_equals("tool_server_tool_not_allowed" in disallowed["body"].get("violations", []), True, "Disallowed-tool violation")
    print("Confirmed: unknown servers and disallowed MCP tools are blocked before inference.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}); Policies tab ({config.CONSOLE['policies']}).")


if __name__ == "__main__":
    main()
