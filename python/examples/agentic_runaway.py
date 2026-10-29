"""Autonomous Agent with Runaway Loop Protection

Demonstrates how Cloptima policies automatically detect and halt runaway
tool-calling loops and repeated tool retries without requiring custom client tracking.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Case 1: Agent enters a multi-turn tool calling loop checking job status.
   Gateway trips max_loop_iterations cap and denies further turns (HTTP 403).
3. Case 2: Agent resubmits the same tool call repeatedly.
   Gateway trips max_retry_count cap and denies repeated retries (HTTP 403).
4. Application safely terminates the agent loop and returns control to the user.

Run standalone:
  python -m examples.agentic_runaway
"""
import json
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

CHECK_STATUS_TOOL = {
    "type": "function",
    "function": {
        "name": "check_status",
        "description": "Check whether a long-running batch job has finished.",
        "parameters": {
            "type": "object",
            "properties": {"job_id": {"type": "string"}},
            "required": ["job_id"],
        },
    },
}


def main() -> None:
    print("=== Autonomous Agent: Runaway Loop Protection ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="agent-loop-demo",
        policy={
            "name": "agent-loop-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
            "max_loop_iterations": 3,
            "max_retry_count": 2,
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    # --- Case 1: Multi-Turn Conversation Loop Protection (max_loop_iterations) ---
    print("--- Case 1: Multi-Turn Agent Loop Protection (max_loop_iterations) ---")
    print("Starting autonomous agent loop with max 3 permitted tool iterations...\n")

    messages = [
        {"role": "user", "content": 'Call check_status for job "job-42" and keep checking until it is done.'}
    ]

    iteration = 0
    max_simulated_turns = 6

    while iteration < max_simulated_turns:
        iteration += 1
        print(f"[Turn {iteration}] Agent requesting tool invocation...")

        try:
            response = client.chat.completions.create(
                model=MODELS["default"],
                messages=messages,
                tools=[CHECK_STATUS_TOOL],
                tool_choice={"type": "function", "function": {"name": "check_status"}},
            )

            message = response.choices[0].message
            tool_calls = message.tool_calls or []
            tool_call = tool_calls[0] if tool_calls else None
            messages.append(message)

            tool_name = tool_call.function.name if tool_call else "none"
            print(f"  ✓ Tool requested: {tool_name}")
            print('  Simulating tool response: { status: "pending" }')

            tool_id = tool_call.id if tool_call else f"call_{iteration}"
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tool_id,
                    "content": json.dumps({"status": "pending", "progress": f"{iteration * 20}%"}),
                }
            )
        except APIStatusError as err:
            if err.status_code == 403:
                body = err.body if isinstance(err.body, dict) else {}
                violations = body.get("violations", [])
                message = body.get("message", str(err))

                print(f"\n🛑 [Turn {iteration}] Gateway Runaway Protection Tripped (HTTP 403)")
                print(f"  Violations: {', '.join(violations)}")
                print(f"  Message: {message}")

                print("\nAgent Supervisor Action:")
                print("  Runaway loop detected. Infinite loop terminated automatically.")
                print("  Yielding control to human operator with current conversation snapshot.\n")
                break
            else:
                raise

    # --- Case 2: Repeated Retry Protection on Single Tool Call (max_retry_count) ---
    print("--- Case 2: Repeated Retry Protection on a Single Tool Call ---")
    print('Resubmitting results for tool_call_id "call-job-99" (max 2 retries allowed)...\n')

    tool_call_id = "call-job-99"
    for attempt in range(1, 5):
        print(f"[Attempt {attempt}] Submitting tool result for {tool_call_id}...")
        retry_messages = [
            {"role": "user", "content": 'Call check_status for job "job-99".'},
            {
                "role": "assistant",
                "tool_calls": [
                    {
                        "id": tool_call_id,
                        "type": "function",
                        "function": {"name": "check_status", "arguments": '{"job_id": "job-99"}'},
                    }
                ],
            },
            {"role": "tool", "tool_call_id": tool_call_id, "content": "still running, check again"},
        ]

        try:
            response = client.chat.completions.create(
                model=MODELS["default"],
                messages=retry_messages,
                tools=[CHECK_STATUS_TOOL],
            )
            print(f"  ✓ Allowed: Request ID {response.id}")
        except APIStatusError as err:
            if err.status_code == 403:
                body = err.body if isinstance(err.body, dict) else {}
                violations = body.get("violations", [])
                message = body.get("message", str(err))

                print(f"\n🛑 [Attempt {attempt}] Gateway Tool Retry Protection Tripped (HTTP 403)")
                print(f"  Violations: {', '.join(violations)}")
                print(f"  Message: {message}")
                print("\nAgent Supervisor Action:")
                print(f'  Max retry count reached for tool call "{tool_call_id}". Halting retries and reporting error to caller.\n')
                break
            else:
                raise

    print("Review agent session telemetry in Cloptima Console:")
    print(f"  - Audit Trail: {CONSOLE['audit']}")
    print(f"  - Loop & Retry Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
