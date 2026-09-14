"""Configures tool I/O capture on an agentic policy, runs a multi-tool agentic
workflow with session correlation, and reads back the cryptographic ledger
audit trail and tool trace records.

In enterprise agentic systems, agents are often given access to multiple tools:
standard lookups (check_order_status), financial actions (issue_refund), and
external data sinks (export_customer_data). Auditing tool invocations and their
exact arguments is critical to detect unintended behavior, prompt injection,
or rogue models transmitting customer data to unapproved external endpoints.

Setting promptRetentionMode: 'tool_io' enables capturing tool calls, arguments,
and results verbatim, while keeping conversational user text and system
prompts uncollected to protect user privacy.

Each step is anchored with a SHA-256 integrity hash (traceSha256) on the
ledger at request time, creating a tamper-evident audit record.

Run standalone from python/:
    python -m examples.session_trace_audit
"""

import json
import random
import time

from openai import APIStatusError

from lib import config
from lib.confirm import confirm_allowed
from lib.gateway_admin import (
    create_binding,
    create_policy,
    create_virtual_key,
    get_llm_agent_session,
    get_llm_agent_session_records,
)
from lib.gateway_clients import openai_style_client
from lib.models import MODEL_DEFAULT

# 1. Read-only order query tool
CHECK_ORDER_TOOL = {
    "type": "function",
    "function": {
        "name": "check_order_status",
        "description": "Look up order fulfillment and delivery status by order ID.",
        "parameters": {
            "type": "object",
            "properties": {
                "order_id": {"type": "string", "description": "The unique order identifier (e.g. ORD-98241)."},
            },
            "required": ["order_id"],
        },
    },
}

# 2. Financial transaction tool
ISSUE_REFUND_TOOL = {
    "type": "function",
    "function": {
        "name": "issue_refund",
        "description": "Authorize and issue a financial refund for an order.",
        "parameters": {
            "type": "object",
            "properties": {
                "order_id": {"type": "string", "description": "The order identifier."},
                "amount_usd": {"type": "number", "description": "Refund amount in USD."},
                "reason": {"type": "string", "description": "Reason for refund."},
            },
            "required": ["order_id", "amount_usd", "reason"],
        },
    },
}

# 3. Sensitive external egress tool (capable of transmitting customer data to external endpoints)
EXPORT_CUSTOMER_DATA_TOOL = {
    "type": "function",
    "function": {
        "name": "export_customer_data",
        "description": "Export customer details, account records, and order history to an external data sink or webhook URL.",
        "parameters": {
            "type": "object",
            "properties": {
                "customer_id": {"type": "string", "description": "The customer identifier."},
                "destination_url": {"type": "string", "description": "External HTTP endpoint or webhook URL to receive exported data."},
                "fields": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Customer record fields to include in export (e.g. email, shipping_address, payment_history).",
                },
            },
            "required": ["customer_id", "destination_url", "fields"],
        },
    },
}

TOOLS = [CHECK_ORDER_TOOL, ISSUE_REFUND_TOOL, EXPORT_CUSTOMER_DATA_TOOL]


def _create_chat_turn(client, model, messages, label):
    """A policy block from the gateway arrives as a non-2xx response, which
    the OpenAI SDK raises as an APIStatusError with .status_code and a parsed
    .body - same classification call_gateway.py uses, inlined here because
    this needs the full multi-turn response object (tool_calls, message
    history), not just the label/outcome shape call_openai_style returns.
    """
    try:
        response = client.chat.completions.create(model=model, messages=messages, tools=TOOLS)
        confirm_allowed({"outcome": "allowed"}, label)
        return response
    except APIStatusError as err:
        status = err.status_code
        reason = getattr(err, "body", None) or str(err)
        outcome = "blocked" if status and 400 <= status < 500 else "error"
        confirm_allowed({"outcome": outcome, "status": status, "reason": reason}, label)
        raise


def main():
    suffix = config.run_suffix()
    app_id = f"support-agent-{suffix}"
    agent_session_id = f"session-{suffix}"
    order_id = f"ORD-{random.randint(10000, 99999)}"
    customer_id = f"CUST-{random.randint(1000, 9999)}"
    external_webhook_url = "https://partner-audit.example.com/ingest"

    # 1. Cloptima setup: policy with tool_io retention, virtual key, and binding.
    print("Creating policy with promptRetentionMode: 'tool_io'...")
    policy = create_policy({
        "name": f"session-trace-audit-{suffix}",
        "mode": "enforce",
        "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": [MODEL_DEFAULT],
        "promptRetentionMode": "tool_io",
    })
    print(f"  policy: {policy['name']} ({policy['id']})")

    print(f'Minting virtual key and binding for app "{app_id}"...')
    key = create_virtual_key({
        "name": f"vk-session-trace-{suffix}",
        "teamId": "Support AI",
        "appId": app_id,
        "environment": "production",
    })
    create_binding({
        "policyId": policy["id"],
        "teamId": "Support AI",
        "appId": app_id,
        "environment": "production",
        "priority": 10,
        "acknowledgeOverlap": True,
    })
    print(f"  key minted: {key['id']}, bound.\n")

    # 2. Application code: official OpenAI SDK client with session correlation.
    # Passing x-cloptima-agent-session-id correlates all steps into one agent session.
    client = openai_style_client(
        key["accessToken"], config.BASE_URL, default_headers={"x-cloptima-agent-session-id": agent_session_id}
    )

    messages = [
        {
            "role": "user",
            "content": (
                f"Check delivery status for order {order_id} (customer {customer_id}). If delivered, export the "
                f"customer delivery confirmation to partner audit sink {external_webhook_url}."
            ),
        },
    ]

    print("Turn 1: User asks for order verification and conditional export...")
    response1 = _create_chat_turn(client, MODEL_DEFAULT, messages, "Turn 1 (tool call)")
    turn_count = 1

    tool_calls1 = response1.choices[0].message.tool_calls
    if not tool_calls1:
        raise RuntimeError("Expected model to return a tool call in Turn 1")
    tool_call1 = tool_calls1[0]
    print(f"  Model invoked: {tool_call1.function.name}({tool_call1.function.arguments})")

    messages.append(response1.choices[0].message)
    messages.append({
        "role": "tool",
        "tool_call_id": tool_call1.id,
        "content": json.dumps({
            "order_id": order_id,
            "customer_id": customer_id,
            "status": "delivered",
            "carrier": "FedEx",
            "delivered_at": "2026-09-14T18:32:00Z",
        }),
    })

    print('\nTurn 2: Feeding status ("delivered") to model; model decides next action...')
    response2 = _create_chat_turn(client, MODEL_DEFAULT, messages, "Turn 2 (agent turn)")
    turn_count += 1

    tool_calls2 = response2.choices[0].message.tool_calls
    if tool_calls2:
        tool_call2 = tool_calls2[0]
        print(f"  Model invoked: {tool_call2.function.name}({tool_call2.function.arguments})")
        print("  -> Destination URL and customer fields captured in tool audit trail.")

        messages.append(response2.choices[0].message)
        transaction_id = f"TXN-{random.randint(100000, 999999)}"
        messages.append({
            "role": "tool",
            "tool_call_id": tool_call2.id,
            "content": json.dumps({
                "status": "success",
                "exported_records": 1,
                "destination_acknowledged": True,
                "transaction_id": transaction_id,
            }),
        })

        print("\nTurn 3: Completing session after tool execution...")
        response3 = _create_chat_turn(client, MODEL_DEFAULT, messages, "Turn 3 (completion)")
        turn_count += 1
        content3 = response3.choices[0].message.content
        print(f'  Model response: "{content3.strip() if content3 else content3}"')
    else:
        content2 = response2.choices[0].message.content
        print(f'  Model response: "{content2.strip() if content2 else content2}"')

    # 3. What the gateway did: inspect the ledger timeline and trace records.
    # Ledger entries land a short moment after the response returns, not
    # instantly - poll briefly instead of assuming a fixed delay is always
    # enough, so the trace hash is reliably present on first read.
    print("\nQuerying session steps from the ledger (llmAgentSession)...")
    session = {}
    for attempt in range(6):
        if attempt > 0:
            time.sleep(0.75)
        session = get_llm_agent_session(agent_session_id)
        steps_so_far = session.get("steps") or []
        if len(steps_so_far) >= turn_count and all(s.get("traceSha256") for s in steps_so_far):
            break
    steps = session.get("steps") or []

    print(f"  Session ID: {session['agentSessionId']} ({len(steps)} steps recorded)")
    for index, step in enumerate(steps):
        print(f"\n  Step {index + 1}:")
        print(f"    Request ID: {step['requestId']}")
        print(f"    Provider / Model: {step['provider']} / {step['model']}")
        print(f"    Status: {step['status']} ({step['inputTokens']} in / {step['outputTokens']} out, cost: ${step['costUsd']})")
        print(f"    Requested tools: {', '.join(step.get('requestedToolNames') or []) or 'none'}")
        print(f"    Invoked tool: {', '.join(step.get('responseToolNames') or []) or 'none'}")
        print(f"    Cryptographic Trace Hash (traceSha256): {step.get('traceSha256') or 'none'}")

    print("\nQuerying session trace records (llmAgentSessionRecords)...")
    records_data = get_llm_agent_session_records(agent_session_id)
    records = records_data.get("records") or []
    print(f"  Trace records available: {len(records)}")
    for rec in records:
        print(f"    Request: {rec['requestId']} -> verification: {rec['verification']}")

    print(
        f"\nEvidence: Sessions tab ({config.CONSOLE['sessions']}?session={agent_session_id}) - inspect multi-turn "
        "tool call pairings, input parameters, and cryptographic verification."
    )


if __name__ == "__main__":
    main()
