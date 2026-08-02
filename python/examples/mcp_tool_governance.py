"""MCP / tool-server governance: register a tool server, allow it (and only
it) on a policy, then exercise the OpenAI Responses API's remote-MCP-tool
path through the managed proxy.

A newly registered tool server is always 'disabled', even if the request
asks for status: 'active' - registration overrides it and auto-queues an
mcp_tool_server_registration approval in the same generic
governance queue as semantic_cache_enforce.py's auto-queued
semantic_cache_enforce entry. Reviewing that approval is the same
second-identity step this repo never scripts (see approval_workflow.py), so
both calls below are expected to be blocked by tool_server_disabled - this
example isn't demonstrating an allowed call, it's demonstrating the
governance gate and that require_approval: 'never' is enforced as its own,
separate rule on top of it: the 'never' call's violations list carries an
additional tool_server_auto_approval_disabled entry the 'always' call
doesn't get, proving that rule holds independently of (and would still apply
once) the tool server is reviewed and made active.

Uses raw requests rather than the openai SDK for these two calls: the SDK's
APIStatusError only surfaces the JSON body, and this example needs to
inspect the sibling `reason`/`violations` fields the gateway actually
returns alongside `error`.
Run standalone from python/:
    python -m examples.mcp_tool_governance
"""

import json

import requests

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql, list_llm_gateway_approvals
from lib.models import MODEL_DEFAULT


def call_responses_api(access_token: str, app_id: str, require_approval: str, server_label: str) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/responses",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {access_token}",
            "x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev",
        },
        json={
            "model": MODEL_DEFAULT,
            "input": f"Test call with require_approval: {require_approval}.",
            "tools": [{"type": "mcp", "server_label": server_label, "allowed_tools": ["search"], "require_approval": require_approval}],
        },
        timeout=30,
    )
    body = response.json()
    outcome = "allowed" if response.status_code == 200 else ("blocked" if 400 <= response.status_code < 500 else "error")
    return {"outcome": outcome, "status": response.status_code, "body": body}


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
            "  This is the one step this script does NOT do: reviewing it requires a second privileged identity in the "
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
    always_result = call_responses_api(key["accessToken"], app_id, "always", server_label)
    print(f"  [{always_result['outcome']}] {json.dumps(always_result)}")

    print("\nCalling again with require_approval: 'never'...")
    never_result = call_responses_api(key["accessToken"], app_id, "never", server_label)
    print(f"  [{never_result['outcome']}] {json.dumps(never_result)}")

    print(
        "\nExpected: both calls are blocked (403) because the tool server above is still 'disabled' pending review - "
        "'always' is blocked by tool_server_disabled alone. 'never' carries that SAME violation plus an additional "
        "tool_server_auto_approval_disabled entry the 'always' call does not get - proving the never-auto-approve "
        "rule is enforced as its own, independent check that would still apply even after this tool server is "
        "reviewed and made active."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for both records and the pending tool-server-registration approval; Policies tab ({config.CONSOLE['policies']}) shows the tool server registration and allowedToolServers config.")


if __name__ == "__main__":
    main()
