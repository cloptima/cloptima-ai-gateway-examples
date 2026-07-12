"""Creates a policy with a realistic maxOutputTokens cap - well above the
platform floor of 64 - and shows a long-response request get blocked
pre-flight rather than silently truncated.
Run standalone from python/:
    python -m examples.token_limit
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum - the platform floor is 64. Change
# this and re-run to see the cap move.
MAX_OUTPUT_TOKENS = 200


def main():
    suffix = config.run_suffix()
    app_id = f"token-limit-{suffix}"

    print(f"Creating policy with maxOutputTokens={MAX_OUTPUT_TOKENS}...")
    policy = create_policy({
        "name": f"token-limit-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "maxOutputTokens": MAX_OUTPUT_TOKENS,
    })
    key = create_virtual_key({"name": f"vk-token-limit-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Requesting a long response the policy should reject...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    result = call_openai_style(
        client, MODEL_DEFAULT,
        "Write a detailed 500-word essay about the history of cloud computing.",
        {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
        "token-limit-probe",
    )

    print(f"[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    print(
        f"\nExpected: blocked pre-flight (403) since the request's default max_tokens exceeds {MAX_OUTPUT_TOKENS}, "
        "with both the requested and allowed values named in the error."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - the block record names both the requested and allowed token values; Policies tab ({config.CONSOLE['policies']}) shows the maxOutputTokens config.")


if __name__ == "__main__":
    main()
