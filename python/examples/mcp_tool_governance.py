"""Enterprise Agent with Governed MCP Tools

Demonstrates how an AI agent calls tools through Cloptima's MCP governance layer,
and how the application handles tool servers and tools that policy does not allow.

Pattern:
1. Governance setup: register tool servers and bind a policy that allows one of them.
   A newly registered server is created `disabled` until it is reviewed.
2. Case 1: Agent calls an allowed tool on an approved server -> admitted.
3. Case 2: Agent references an unregistered server -> blocked with HTTP 403.
4. Case 3: Agent requests a tool the server does not allow -> blocked with HTTP 403.

Needs CLOPTIMA_AI_ADMIN_KEY (registers tool servers and a policy).

Run standalone:
  python -m examples.mcp_tool_governance
"""
import requests

from lib import config, gateway_admin
from lib.access import provision_app
from lib.client import openai_client
from lib.config import BASE_URL, CONSOLE, USER_AGENT
from lib.models import MODELS

CREATE_TOOL_SERVER = """mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
  createLLMGatewayToolServer(input: $input) { id name status }
}"""


def call_with_mcp_server(virtual_key: str, server_label: str, allowed_tools: list) -> dict:
    response = requests.post(
        f"{BASE_URL}/v1/ai/responses",
        headers={
            "content-type": "application/json",
            "user-agent": USER_AGENT,
            "authorization": f"Bearer {virtual_key}",
        },
        json={
            "model": MODELS["default"],
            "input": "Run the requested maintenance task.",
            "tools": [
                {
                    "type": "mcp",
                    "server_label": server_label,
                    "allowed_tools": allowed_tools,
                    "require_approval": "always",
                }
            ],
        },
        timeout=30,
    )
    if response.status_code == 403:
        try:
            body = response.json()
        except Exception:
            body = {}
        return {"blocked": True, "violations": body.get("violations", [])}
    return {"blocked": False, "violations": []}


def main() -> None:
    print("=== Enterprise Agent: MCP Tool Governance ===\n")
    suffix = config.run_suffix()

    # --- Governance setup (admin) -------------------------------------------------------------
    print("Registering a new tool server (awaiting security review)...")
    res = gateway_admin.graphql(
        CREATE_TOOL_SERVER,
        {
            "input": {
                "name": f"mcp-pending-{suffix}",
                "serverType": "mcp",
                "serverUrl": "https://mcp.example.com/v1",
                "status": "active",
                "allowedToolNames": ["search", "lookup"],
            }
        },
    )
    pending_server = res["createLLMGatewayToolServer"]
    print(f'  {pending_server["name"]}: status "{pending_server["status"]}" until an admin approves the registration.')

    pending = gateway_admin.list_llm_gateway_approvals(status="pending", limit=50)
    registration = next(
        (a for a in pending if a.get("approvalType") == "mcp_tool_server_registration" and a.get("targetId") == pending_server["id"]),
        None,
    )
    if registration:
        print(f"  Review queued as approval {registration['id']} ({CONSOLE['audit']}).")

    print("\nRegistering a reviewed tool server with applyImmediately: true...")
    server_label = f"mcp-github-{suffix}"
    res2 = gateway_admin.graphql(
        CREATE_TOOL_SERVER,
        {
            "input": {
                "name": server_label,
                "serverType": "mcp",
                "serverUrl": "https://mcp.github.example/v1",
                "status": "active",
                "allowedToolNames": ["create_issue", "list_issues"],
                "applyImmediately": True,
            }
        },
    )
    active_server = res2["createLLMGatewayToolServer"]
    print(f'  {active_server["name"]}: status "{active_server["status"]}"')

    setup = provision_app(
        app="mcp-agent-demo",
        policy={
            "name": "mcp-agent-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "allowedToolServers": [server_label],  # the agent may only use this tool server
        },
    )
    virtual_key = setup["virtual_key"]

    # --- Application code ----------------------------------------------------------------------
    client = openai_client(virtual_key)

    print("\n--- Case 1: Allowed Tool on an Approved Server ---")
    response = client.chat.completions.create(
        model=MODELS["default"],
        messages=[{"role": "user", "content": 'Open an issue titled "Update documentation" on GitHub.'}],
        tools=[
            {
                "type": "function",
                "function": {
                    "name": "create_issue",
                    "description": "Create a new issue on a GitHub repository",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string", "description": "The issue title"},
                            "body": {"type": "string", "description": "The issue description"},
                        },
                        "required": ["title"],
                    },
                    "mcp_server": server_label,
                },
            }
        ],
    )

    message = response.choices[0].message
    tool_calls = message.tool_calls or []
    tool_call = tool_calls[0] if tool_calls else None
    print("Gateway status: Allowed (HTTP 200)")
    if tool_call:
        print(f"Model selected tool: {tool_call.function.name}({tool_call.function.arguments})")
    else:
        content = message.content or ""
        print(f"Model response: {content.strip()}")

    print("\n--- Case 2: Unregistered Tool Server ---")
    unknown = call_with_mcp_server(virtual_key, "unregistered-server", ["create_issue"])
    if unknown["blocked"]:
        print(f"Blocked before inference (HTTP 403). Violations: {', '.join(unknown['violations'])}")
    else:
        print("Admitted unexpectedly.")

    print("\n--- Case 3: Tool Not on the Server Allowlist ---")
    disallowed = call_with_mcp_server(virtual_key, server_label, ["drop_database"])
    if disallowed["blocked"]:
        print(f"Blocked before inference (HTTP 403). Violations: {', '.join(disallowed['violations'])}")
        print("Application action: abort the tool call and return control to the user.")
    else:
        print("Admitted unexpectedly.")

    print("\nEvidence in Cloptima Console:")
    print(f"  - Audit trail: {CONSOLE['audit']}")
    print(f"  - Registered tool servers & policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
