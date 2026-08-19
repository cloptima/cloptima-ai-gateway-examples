"""Creates a Vertex-only policy and requests a non-Vertex model through it,
showing a provider-scope block rather than a silent fallback.
Run standalone from python/:
    python -m examples.provider_deny
"""

import json

from lib import config
from lib.confirm import confirm_blocked
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    app_id = f"provider-deny-{suffix}"

    # 1. Cloptima setup - the policy, key, and binding are the whole contract.
    print("Creating a Vertex-only policy...")
    policy = create_policy({
        "name": f"provider-deny-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
    })
    key = create_virtual_key({"name": f"vk-provider-deny-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Requesting a non-Vertex model through it...\n")

    # 2. Your application code - the official OpenAI SDK, unchanged.
    client = openai_style_client(key["accessToken"], config.BASE_URL)
    result = call_openai_style(
        client, "openai/gpt-4o",
        "This call should be denied - non-Vertex provider.",
        "provider-deny-probe",
    )

    # 3. What the gateway did. confirm_blocked stops the script if the policy
    # above was not held, so a silent regression cannot print as a success.
    print(f"[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    confirm_blocked(result, "allowedProviders=[vertex_ai]", status=403, violation="provider is not allowed")
    print(f"\nConfirmed: blocked ({result.get('status')}) - the policy only allows vertex_ai, so a non-Vertex model is denied before provider egress.")
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by app \"{app_id}\" for the provider-scope block record.")


if __name__ == "__main__":
    main()
