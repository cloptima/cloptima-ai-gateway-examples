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
from lib.confirm import confirm_cap_stopped
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. Bounds: dailyBudgetUsd accepts 0-10,000,000.
DAILY_BUDGET_USD = 0.01
MAX_TOKENS_PER_CALL = 100
# At current catalog rates this budget is observed to cross around call ~46.
# Keep real headroom above that rather than cutting it close to the
# theoretical minimum, so a routine pricing update doesn't silently make
# this loop exhaust MAX_CALLS before ever seeing the 402.
MAX_CALLS = 60


def call_chat(virtual_key: str, model: str, prompt: str) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/chat/completions",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {virtual_key}",
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

    # 1. Cloptima setup - the policy, key, and binding are the whole contract.
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

    # 2. Your application code.
    results = []
    for i in range(MAX_CALLS):
        result = call_chat(key["accessToken"], MODEL_DEFAULT, f'Budget probe {i + 1}. Reply with just "ok".')
        results.append({"label": f"call-{i + 1}", **result})
        print(f"  [{'allowed' if result['status'] == 200 else 'blocked'}] call-{i + 1} status={result['status']}")
        if result["status"] != 200:
            break

    # 3. What the gateway did. confirm_cap_stopped stops the script if the budget
    # never denied a call, so a silent regression cannot print as a success.
    outcomes = [{"label": r["label"], "status": r["status"], "outcome": "allowed" if r["status"] == 200 else "blocked", "reason": r["body"]} for r in results]
    cap_info = confirm_cap_stopped(outcomes, f"dailyBudgetUsd={DAILY_BUDGET_USD}", status=402)
    allowed_count = cap_info["allowed_count"]
    blocked = cap_info["blocked"]
    print(f"\n{allowed_count} calls served, then {blocked['label']} returned {blocked['status']} once the ${DAILY_BUDGET_USD}/day policy budget was exhausted.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for the 402 block record; Explorer tab ({config.CONSOLE['spend']}) shows the spend accumulated right up to the cap.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
