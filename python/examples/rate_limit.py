"""Creates a policy with a realistic per-minute request rate cap, fires calls
fast enough to exceed it, and shows the 429 once the cap is hit.
Rate limits are evaluated per calendar minute (e.g. 10:00:00-10:00:59 UTC), not rolling 60s.

Run standalone from python/:
    python -m examples.rate_limit
"""

import json
import time
from datetime import datetime, timezone

from lib import config
from lib.confirm import confirm_cap_stopped
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum - change this and re-run to see the
# cap move. Bounds: requestRateLimitPerMinute accepts 1-1,000,000.
REQUEST_RATE_LIMIT_PER_MINUTE = 20
CALLS_TO_FIRE = 25


def start_of_calendar_minute():
    """Rate limits are evaluated per calendar minute, so a burst that straddles a
    minute boundary is split across two windows and can stay under the cap in
    both. Waiting for a fresh window keeps the demonstration deterministic
    instead of dependent on what time it happens to run.
    """
    seconds_left = 60 - datetime.now(timezone.utc).second
    if seconds_left >= CALLS_TO_FIRE + 5:
        return
    print(f"Waiting {seconds_left}s for the next calendar minute so the whole burst lands in one window...")
    time.sleep(seconds_left)


def main():
    suffix = config.run_suffix()
    app_id = f"rate-limit-{suffix}"

    # 1. Cloptima setup - the policy, key, and binding are the whole contract.
    print(f"Creating policy with requestRateLimitPerMinute={REQUEST_RATE_LIMIT_PER_MINUTE}...")
    policy = create_policy({
        "name": f"rate-limit-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "requestRateLimitPerMinute": REQUEST_RATE_LIMIT_PER_MINUTE,
    })
    key = create_virtual_key({"name": f"vk-rate-limit-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.")

    # 2. Your application code - the official OpenAI SDK, unchanged.
    start_of_calendar_minute()
    print(f"Firing {CALLS_TO_FIRE} calls back-to-back...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    results = []
    for i in range(CALLS_TO_FIRE):
        result = call_openai_style(
            client, MODEL_DEFAULT,
            f'Rate limit probe {i + 1}. Reply with just "ok".',
            f"call-{i + 1}",
        )
        results.append(result)
        print(f"  [{result['outcome']}] call-{i + 1} status={result.get('status', 200)}")
        if result["outcome"] != "allowed":
            break

    # 3. What the gateway did. confirm_cap_stopped stops the script if the cap
    # never fired, so a silent regression cannot print as a success.
    cap_info = confirm_cap_stopped(
        results,
        f"requestRateLimitPerMinute={REQUEST_RATE_LIMIT_PER_MINUTE}",
        status=429,
        expected_allowed=REQUEST_RATE_LIMIT_PER_MINUTE,
    )
    allowed_count = cap_info["allowed_count"]
    blocked = cap_info["blocked"]
    print(f"\n{allowed_count} calls served, then {blocked['label']} returned {blocked['status']} once the {REQUEST_RATE_LIMIT_PER_MINUTE}/minute cap was reached.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for the 429 block record; Policies tab ({config.CONSOLE['policies']}) shows the requestRateLimitPerMinute config that fired.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
