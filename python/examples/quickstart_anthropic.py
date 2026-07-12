"""Same idea as quickstart_openai.py, using the Anthropic SDK's own calling
convention instead - proves both API shapes work against the same gateway.
Run standalone from python/:
    python -m examples.quickstart_anthropic
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import anthropic_style_client
from lib.call_gateway import call_anthropic_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    app_id = f"quickstart-anthropic-{suffix}"

    print(f"Creating policy allowing {MODEL_DEFAULT} on the managed Vertex AI provider...")
    policy = create_policy({
        "name": f"quickstart-anthropic-{suffix}",
        "mode": "enforce",
        "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": [MODEL_DEFAULT],
    })
    print(f"  policy {policy['name']} -> {policy['id']}")

    print("Minting a virtual key scoped to this policy...")
    key = create_virtual_key({
        "name": f"vk-quickstart-anthropic-{suffix}",
        "teamId": "Quickstart", "appId": app_id, "environment": "dev",
    })
    print(f"  key {key['id']}")

    create_binding({"policyId": policy["id"], "teamId": "Quickstart", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print("Bound. Calling the gateway with the official Anthropic SDK...")

    client = anthropic_style_client(key["accessToken"], config.BASE_URL)
    result = call_anthropic_style(
        client, MODEL_DEFAULT,
        "In one sentence, confirm this call went through Cloptima's managed AI gateway.",
        {"x-cloptima-team": "Quickstart", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
        "quickstart-anthropic",
    )

    print(f"\n[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    print(f"\nEvidence: Explorer tab ({config.CONSOLE['spend']}) - find this request_id to see attributed spend and usage.")


if __name__ == "__main__":
    main()
