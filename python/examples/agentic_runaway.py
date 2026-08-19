"""Creates policies with realistic agentic-loop and retry limits and drives
real tool-calling conversations against the gateway, showing which turns
succeed vs. get blocked.

Both limits are derived entirely from the tool-call transcript already
present in each request body - the growing sequence of tool calls and
results a normal tool-calling client already sends for the model to have
any memory of what it already tried. No client-declared session, step, or
retry identifiers are involved anywhere below.

Loop depth counts completed tool-result turns in the conversation so far.
Retry count is scoped per tool_call_id, so retrying one specific call and
starting a new, different call are counted independently.

Run standalone from python/:
    python -m examples.agentic_runaway
"""

import json

from openai import APIStatusError

from lib import config
from lib.confirm import confirm_allowed, confirm_cap_stopped
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
MAX_LOOP_ITERATIONS = 3
MAX_RETRY_COUNT = 2

CHECK_STATUS_TOOL = {
    "type": "function",
    "function": {
        "name": "check_status",
        "description": "Check whether a long-running job has finished.",
        "parameters": {
            "type": "object",
            "properties": {"job_id": {"type": "string"}},
            "required": ["job_id"],
        },
    },
}


def _blocked_outcome(index: int, err: APIStatusError) -> dict:
    return {"index": index, "outcome": "blocked", "status": err.status_code, "reason": getattr(err, "body", None) or str(err)}


def run_loop_iterations(client, model, iterations_to_simulate):
    """Forces a real tool call every turn and feeds back a synthetic "still
    running" result, then asks again - a realistic runaway-loop pattern.
    Each turn resends the whole conversation so far, including every prior
    tool call and result, exactly like a normal tool-calling client would.
    """
    messages = [{"role": "user", "content": 'Call check_status for job "job-42" and keep checking until it is done.'}]
    results = []
    for i in range(iterations_to_simulate):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                tools=[CHECK_STATUS_TOOL],
                tool_choice={"type": "function", "function": {"name": "check_status"}},
            )
        except APIStatusError as err:
            results.append(_blocked_outcome(i, err))
            break
        tool_call = response.choices[0].message.tool_calls[0]
        results.append({"index": i, "outcome": "allowed", "request_id": response.id, "tool_call_id": tool_call.id})
        messages.append({
            "role": "assistant",
            "tool_calls": [{
                "id": tool_call.id,
                "type": "function",
                "function": {"name": tool_call.function.name, "arguments": tool_call.function.arguments},
            }],
        })
        messages.append({"role": "tool", "tool_call_id": tool_call.id, "content": "still running, check again"})
    return results


def run_retry_iterations(client, model, tool_call_id, iterations_to_simulate):
    """Resubmits the SAME tool_call_id's result repeatedly - a client
    retrying one specific call. Retry scope is per tool_call_id, so this is
    independent of loop depth and of any other call id.
    """
    results = []
    for i in range(iterations_to_simulate):
        messages = [
            {"role": "user", "content": 'Call check_status for job "job-99".'},
            {
                "role": "assistant",
                "tool_calls": [{
                    "id": tool_call_id,
                    "type": "function",
                    "function": {"name": "check_status", "arguments": '{"job_id": "job-99"}'},
                }],
            },
            {"role": "tool", "tool_call_id": tool_call_id, "content": "still running, check again"},
        ]
        try:
            response = client.chat.completions.create(model=model, messages=messages, tools=[CHECK_STATUS_TOOL])
            results.append({"index": i, "outcome": "allowed", "request_id": response.id})
        except APIStatusError as err:
            results.append(_blocked_outcome(i, err))
    return results


def main():
    suffix = config.run_suffix()

    # 1. Cloptima setup - the policy, key, and binding are the whole contract.
    loop_app_id = f"agentic-loop-{suffix}"
    print(f"Creating policy with maxLoopIterations={MAX_LOOP_ITERATIONS}...")
    loop_policy = create_policy({
        "name": f"agentic-loop-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "maxLoopIterations": MAX_LOOP_ITERATIONS,
    })
    loop_key = create_virtual_key({"name": f"vk-agentic-loop-{suffix}", "teamId": "Platform AI", "appId": loop_app_id, "environment": "dev"})
    create_binding({"policyId": loop_policy["id"], "teamId": "Platform AI", "appId": loop_app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {loop_key['id']}, bound.\n")

    # 2. Your application code - the official OpenAI SDK, unchanged.
    loop_client = openai_style_client(loop_key["accessToken"], config.BASE_URL)
    loop_iterations_to_simulate = MAX_LOOP_ITERATIONS + 2
    print(f"Driving a real tool-calling loop for {loop_iterations_to_simulate} turns...\n")
    loop_results = run_loop_iterations(loop_client, MODEL_DEFAULT, loop_iterations_to_simulate)
    for r in loop_results:
        print(f"  [{r['outcome']}] turn {r['index']}")

    # 3. What the gateway did.
    confirm_cap_stopped(
        loop_results,
        f"maxLoopIterations={MAX_LOOP_ITERATIONS}",
        status=403,
        expected_allowed=MAX_LOOP_ITERATIONS + 1,
    )
    print(
        f"\nConfirmed: turns 0-{MAX_LOOP_ITERATIONS} served, turn {MAX_LOOP_ITERATIONS + 1} blocked "
        '("exceeds the active Cloptima agent limits") - counted from the tool-call turns already present in the '
        "conversation, not any client-supplied count."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{loop_app_id}\" for the blocked turn.")
    print(json.dumps(loop_results, indent=2, default=str))

    retry_app_id = f"agentic-retry-{suffix}"
    print(f"\nCreating policy with maxRetryCount={MAX_RETRY_COUNT}...")
    retry_policy = create_policy({
        "name": f"agentic-retry-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "maxRetryCount": MAX_RETRY_COUNT,
    })
    retry_key = create_virtual_key({"name": f"vk-agentic-retry-{suffix}", "teamId": "Platform AI", "appId": retry_app_id, "environment": "dev"})
    create_binding({"policyId": retry_policy["id"], "teamId": "Platform AI", "appId": retry_app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {retry_key['id']}, bound.\n")

    retry_client = openai_style_client(retry_key["accessToken"], config.BASE_URL)
    retry_iterations_to_simulate = MAX_RETRY_COUNT + 2
    print(f"Resubmitting the same tool call {retry_iterations_to_simulate} times...\n")
    retry_results = run_retry_iterations(retry_client, MODEL_DEFAULT, "call-job-99", retry_iterations_to_simulate)
    for r in retry_results:
        print(f"  [{r['outcome']}] attempt {r['index']}")

    confirm_cap_stopped(
        retry_results,
        f"maxRetryCount={MAX_RETRY_COUNT}",
        status=403,
        expected_allowed=MAX_RETRY_COUNT + 1,
    )
    print(
        f"\nConfirmed: attempts 0-{MAX_RETRY_COUNT} served, attempt {MAX_RETRY_COUNT + 1} blocked - counted "
        "per tool_call_id, so a different call id gets its own independent count."
    )
    other_call_result = run_retry_iterations(retry_client, MODEL_DEFAULT, "call-job-100", 1)[0]
    confirm_allowed(other_call_result, "a different tool_call_id starts its own retry count")
    print(f"  [{other_call_result['outcome']}] a different tool_call_id, first attempt")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{retry_app_id}\" for the blocked attempt.")
    print(json.dumps(retry_results + [other_call_result], indent=2, default=str))


if __name__ == "__main__":
    main()
