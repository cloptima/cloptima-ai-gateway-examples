"""Creates a policy with realistic agentic-loop limits and simulates an agent
retrying/looping via escalating x-cloptima-loop-iteration/retry-index
headers, showing which iterations succeed vs. get blocked.
Run standalone from python/:
    python -m examples.agentic_runaway
"""

import json
import uuid

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
MAX_RETRY_COUNT = 5
MAX_LOOP_ITERATIONS = 5
ITERATIONS_TO_SIMULATE = 8


def main():
    suffix = config.run_suffix()
    app_id = f"agentic-runaway-{suffix}"

    print(f"Creating policy with maxRetryCount={MAX_RETRY_COUNT}, maxLoopIterations={MAX_LOOP_ITERATIONS}...")
    policy = create_policy({
        "name": f"agentic-runaway-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "maxRetryCount": MAX_RETRY_COUNT,
        "maxLoopIterations": MAX_LOOP_ITERATIONS,
    })
    key = create_virtual_key({"name": f"vk-agentic-runaway-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Simulating {ITERATIONS_TO_SIMULATE} escalating loop iterations...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    session_id = str(uuid.uuid4())
    results = []
    for i in range(ITERATIONS_TO_SIMULATE):
        result = call_openai_style(
            client, MODEL_DEFAULT,
            'Simulated agent loop step. Reply with just "ok".',
            {
                "x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev",
                "x-cloptima-agent-session-id": session_id,
                "x-cloptima-loop-iteration": str(i),
                "x-cloptima-retry-index": str(i),
            },
            f"loop-iteration-{i}",
        )
        results.append(result)
        print(f"  [{result['outcome']}] loop-iteration-{i}")

    print(
        f"\nExpected: iterations 0-{MAX_LOOP_ITERATIONS} allowed, iteration {MAX_LOOP_ITERATIONS + 1} onward blocked "
        '("exceeds the active Cloptima agent limits") - this is what catches a genuinely runaway agent loop.'
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by agent session \"{session_id}\" for the blocked loop iterations.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
