"""Autonomous Enterprise Agent: Cryptographic Session Ledger & Tool I/O Auditing

In enterprise agentic systems, autonomous agents often execute sensitive operations:
- Querying order and customer records (check_order_status)
- Authorizing financial transactions (issue_refund)
- Transmitting customer records to third-party endpoints (export_customer_data)

For compliance, security, and forensics, organizations must audit exact tool parameters
without storing sensitive conversational user text.

Cloptima provides:
1. Selective Prompt Retention (promptRetentionMode: 'tool_io'): Tool calls, arguments,
   and results are captured verbatim for compliance, while user chat text is omitted.
2. Cryptographic Session Ledger: Every step in an agent session is correlated via
   'x-cloptima-agent-session-id' and anchored with a SHA-256 integrity hash (traceSha256).

Run standalone:
  python -m examples.session_trace_audit
"""
import json
import random
import time
from typing import Optional

from lib import config, gateway_admin
from lib.access import provision_app
from lib.client import openai_client
from lib.models import MODELS

TOOLS = [
    {
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
    },
    {
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
    },
    {
        "type": "function",
        "function": {
            "name": "export_customer_data",
            "description": "Export customer details and order records to an external compliance audit endpoint.",
            "parameters": {
                "type": "object",
                "properties": {
                    "customer_id": {"type": "string", "description": "The customer identifier."},
                    "destination_url": {"type": "string", "description": "External webhook URL."},
                    "fields": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Customer record fields to include in export.",
                    },
                },
                "required": ["customer_id", "destination_url", "fields"],
            },
        },
    },
]


def main() -> None:
    suffix = config.run_suffix()
    agent_session_id = f"session-{suffix}"
    order_id = f"ORD-{random.randint(10000, 99999)}"
    customer_id = f"CUST-{random.randint(1000, 9999)}"
    external_webhook_url = "https://partner-audit.example.com/ingest"

    print(f"Connecting to Cloptima Gateway with session correlation ({agent_session_id})...")
    setup = provision_app(
        app="support-agent-demo",
        policy={
            "name": "session-trace-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "promptRetentionMode": "tool_io",  # capture tool calls and results, omit user chat text
        },
    )

    client = openai_client(
        setup["virtual_key"],
        default_headers={"x-cloptima-agent-session-id": agent_session_id},
    )

    messages = [
        {
            "role": "system",
            "content": (
                "You are an enterprise support automation agent. If an order has been delivered, "
                "you must export the customer delivery confirmation record to the audit sink."
            ),
        },
        {
            "role": "user",
            "content": (
                f"Check delivery status for order {order_id} (customer {customer_id}). "
                f"If delivered, export the customer delivery confirmation to partner audit sink {external_webhook_url}."
            ),
        },
    ]

    turn_count = 0

    # Turn 1: Model decides to check order status
    print("\n[Agent Turn 1] User issues multi-step order inspection request...")
    response1 = client.chat.completions.create(
        model=MODELS["default"],
        messages=messages,
        tools=TOOLS,
        tool_choice={"type": "function", "function": {"name": "check_order_status"}},
    )
    turn_count += 1

    msg1 = response1.choices[0].message
    tool_calls1 = msg1.tool_calls or []
    tool_call1 = tool_calls1[0] if tool_calls1 else None
    if not tool_call1:
        raise RuntimeError("Expected agent to invoke check_order_status tool.")

    print(f"Model invoked tool: {tool_call1.function.name}({tool_call1.function.arguments})")
    messages.append(msg1)
    messages.append({
        "role": "tool",
        "tool_call_id": tool_call1.id,
        "content": json.dumps({
            "order_id": order_id,
            "status": "delivered",
            "delivered_at": "2026-03-29T10:15:00Z",
            "carrier": "FedEx",
            "tracking_number": "TRK-748920194",
        }),
    })

    # Turn 2: Feed tool output to model; model decides to export data
    print("\n[Agent Turn 2] Feeding delivery status to agent; agent executes conditional action...")
    response2 = client.chat.completions.create(
        model=MODELS["default"],
        messages=messages,
        tools=TOOLS,
    )
    turn_count += 1

    msg2 = response2.choices[0].message
    tool_calls2 = msg2.tool_calls or []
    tool_call2 = tool_calls2[0] if tool_calls2 else None
    if tool_call2:
        print(f"Model invoked tool: {tool_call2.function.name}({tool_call2.function.arguments})")
        print("-> Destination URL and exported fields captured in Cloptima tool audit trail.")
        messages.append(msg2)
        messages.append({
            "role": "tool",
            "tool_call_id": tool_call2.id,
            "content": json.dumps({"exported": True, "destination": external_webhook_url, "record_count": 1}),
        })

        # Turn 3: Complete interaction
        print("\n[Agent Turn 3] Finalizing customer response...")
        response3 = client.chat.completions.create(
            model=MODELS["default"],
            messages=messages,
            tools=TOOLS,
        )
        turn_count += 1
        content3 = response3.choices[0].message.content or ""
        print(f'Agent Final Answer: "{content3.strip()}"')
    else:
        content2 = msg2.content or ""
        print(f'Agent Final Answer: "{content2.strip()}"')

    # Compliance Audit & Cryptographic Verification
    print("\n--- Compliance Audit: Querying Cryptographic Session Ledger ---")
    session: Optional[dict] = None
    for attempt in range(6):
        if attempt > 0:
            time.sleep(1.0)
        try:
            session = gateway_admin.get_llm_agent_session(session_id=agent_session_id)
            steps = (session or {}).get("steps") or []
            if len(steps) >= turn_count and all(s.get("traceSha256") for s in steps):
                break
        except Exception:
            pass

    steps = (session or {}).get("steps") or []
    print(f"Session Correlated: {(session or {}).get('agentSessionId') or agent_session_id} ({len(steps)} steps recorded)")
    for index, step in enumerate(steps):
        print(f"\n  Step {index + 1}:")
        print(f"    Request ID:    {step.get('requestId')}")
        print(f"    Provider/Model: {step.get('provider')} / {step.get('model')}")
        print(f"    Status:        {step.get('status')} ({step.get('inputTokens')} in / {step.get('outputTokens')} out, cost: ${step.get('costUsd')})")
        invoked = ", ".join(step.get("responseToolNames") or []) or "none"
        print(f"    Invoked Tool:  {invoked}")
        print(f"    Trace SHA-256: {step.get('traceSha256') or 'none'}")

    records_data = gateway_admin.get_llm_agent_session_records(session_id=agent_session_id)
    records = (records_data or {}).get("records") or []
    print(f"\nVerified tamper-evident records: {len(records)} tool trace items anchored to ledger.")
    for rec in records:
        print(f"  Request {rec.get('requestId')} -> verification: {rec.get('verification')}")


if __name__ == "__main__":
    main()
