"""Creates a policy with a realistic per-minute request rate cap, fires calls
fast enough to exceed it, and shows the 429 once the cap is hit.
Run standalone from python/:
    python -m examples.rate_limit
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum - change this and re-run to see the
# cap move. Bounds: requestRateLimitPerMinute accepts 1-1,000,000.
REQUEST_RATE_LIMIT_PER_MINUTE = 20
CALLS_TO_FIRE = 25


def main():
    suffix = config.run_suffix()
    app_id = f"rate-limit-{suffix}"

    print(f"Creating policy with requestRateLimitPerMinute={REQUEST_RATE_LIMIT_PER_MINUTE}...")
    policy = create_policy({
        "name": f"rate-limit-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "requestRateLimitPerMinute": REQUEST_RATE_LIMIT_PER_MINUTE,
    })
    key = create_virtual_key({"name": f"vk-rate-limit-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Firing {CALLS_TO_FIRE} calls back-to-back...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    results = []
    for i in range(CALLS_TO_FIRE):
        result = call_openai_style(
            client, MODEL_DEFAULT,
            f'Rate limit probe {i + 1}. Reply with just "ok".',
            {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
            f"call-{i + 1}",
        )
        results.append(result)
        print(f"  [{result['outcome']}] call-{i + 1} status={result.get('status', 200)}")
        if result["outcome"] != "allowed":
            break

    allowed_count = sum(1 for r in results if r["outcome"] == "allowed")
    print(f"\n{allowed_count} calls allowed before the {REQUEST_RATE_LIMIT_PER_MINUTE}/minute cap returned 429.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for the 429 block record; Policies tab ({config.CONSOLE['policies']}) shows the requestRateLimitPerMinute config that fired.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
