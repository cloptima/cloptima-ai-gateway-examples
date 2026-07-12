"""Creates a hard_strict policy with a small but real per-policy daily budget,
distinct from the org-wide managed-credits wallet cap, and fires calls in a
loop until the budget denies the rest.

hard_strict reserves against an ESTIMATED cost derived from the request's
max_tokens (a pessimistic worst case), not the realized post-completion cost -
so this script passes an explicit, modest max_tokens on every call to keep
that estimate small and consistent. Without that, an unbounded default
max_tokens would make the very first call's estimate blow past a small
budget and trip on call 1 regardless of the budget's actual size.
Run standalone from python/:
    python -m examples.budget_limit
"""

import json

import requests

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. Bounds: dailyBudgetUsd accepts 0-10,000,000.
DAILY_BUDGET_USD = 0.01
MAX_TOKENS_PER_CALL = 100
MAX_CALLS = 40


def call_chat(virtual_key: str, model: str, prompt: str, app_id: str) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/chat/completions",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {virtual_key}",
            "x-cloptima-team": "Platform AI",
            "x-cloptima-app": app_id,
            "x-cloptima-environment": "dev",
        },
        json={"model": model, "max_tokens": MAX_TOKENS_PER_CALL, "messages": [{"role": "user", "content": prompt}]},
        timeout=30,
    )
    try:
        body = response.json()
    except ValueError:
        body = None
    return {"status": response.status_code, "body": body}


def main():
    suffix = config.run_suffix()
    app_id = f"budget-limit-{suffix}"

    print(f"Creating hard_strict policy with dailyBudgetUsd=${DAILY_BUDGET_USD}...")
    policy = create_policy({
        "name": f"budget-limit-{suffix}",
        "mode": "enforce", "budgetMode": "hard_strict",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "dailyBudgetUsd": DAILY_BUDGET_USD,
    })
    key = create_virtual_key({"name": f"vk-budget-limit-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Firing calls (max {MAX_CALLS}) until the budget denies...\n")

    results = []
    for i in range(MAX_CALLS):
        result = call_chat(key["accessToken"], MODEL_DEFAULT, f'Budget probe {i + 1}. Reply with just "ok".', app_id)
        results.append({"label": f"call-{i + 1}", **result})
        print(f"  [{'allowed' if result['status'] == 200 else 'blocked'}] call-{i + 1} status={result['status']}")
        if result["status"] != 200:
            break

    allowed_count = sum(1 for r in results if r["status"] == 200)
    print(f"\n{allowed_count} calls allowed before the ${DAILY_BUDGET_USD}/day policy budget returned 402.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for the 402 block record; Explorer tab ({config.CONSOLE['spend']}) shows the spend accumulated right up to the cap.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
