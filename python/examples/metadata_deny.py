"""FinOps Attribution: Mandatory Team & App Metadata

Demonstrates how enterprise organizations enforce chargeback and cost allocation
by requiring attribution headers on all managed inference requests.

Pattern:
1. Initialize client using an unscoped virtual key (no team or app baked in).
2. Case 1: Call without attribution metadata -> Gateway refuses with HTTP 400.
3. Case 2: Call with proper x-cloptima-team and x-cloptima-app headers -> Admitted.

Auth: CLOPTIMA_AI_ADMIN_KEY creates the policy and an unscoped key. CLOPTIMA_VIRTUAL_KEY must be
an unscoped key bound to a policy that requires team_id, app_id, and environment; a key with team
and app baked in supplies its own attribution, so Case 1 would not be refused.

Run standalone:
  python -m examples.metadata_deny
"""
from openai import APIStatusError

from lib import config, gateway_admin
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== FinOps Attribution: Enforcing Team & Application Tags ===\n")

    suffix = config.run_suffix()
    if config.VIRTUAL_KEY:
        print("Using CLOPTIMA_VIRTUAL_KEY. It should be an unscoped key bound to a policy requiring attribution metadata.\n")
        virtual_key = config.VIRTUAL_KEY
    elif config.AI_ADMIN_KEY:
        print("Configuring policy requiring attribution metadata...")
        policy = gateway_admin.create_policy({
            "name": f"attribution-policy-{suffix}",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
            "metadata": {"required_metadata_keys": ["team_id", "app_id", "environment"]},
        })

        # Key created without baked-in team/app to demonstrate header-driven attribution
        key = gateway_admin.create_virtual_key({"name": f"vk-attribution-{suffix}"})

        gateway_admin.create_binding({
            "policy_id": policy["id"],
            "principal_id": key["id"],
            "actor_type": "service",
            "priority": 5,
            "acknowledge_overlap": True,
        })
        virtual_key = key["access_token"]
    else:
        raise RuntimeError(
            "Set CLOPTIMA_VIRTUAL_KEY to use an existing key, or CLOPTIMA_AI_ADMIN_KEY to let this example create its own policy and key (see .env.example)."
        )

    client = openai_client(virtual_key)

    # Case 1: Calling without required attribution headers
    print("--- Case 1: Unattributed Request (Missing Headers) ---")
    try:
        client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "Execute unallocated query."}],
        )
        print("Assistant: (Admitted unexpectedly)\n")
    except APIStatusError as err:
        if err.status_code in (400, 403):
            body = err.body if isinstance(err.body, dict) else {}
            message = body.get("message", str(err))

            print("🛑 Gateway Attribution Enforcement (HTTP 400)")
            print(f"  Message: {message}")
            print("\nApplication Action:")
            print("  Request rejected because team and application cost centers were not provided.\n")
        else:
            raise

    # Case 2: Supplying attribution headers
    print("--- Case 2: Attributed Request (With Cost Center Headers) ---")
    team_id = "Payment-Services"
    app_id = "checkout-fraud-detection"
    print(f'Injecting headers: x-cloptima-team="{team_id}", x-cloptima-app="{app_id}"')

    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "Explain fraud detection scoring briefly."}],
            extra_headers={
                "x-cloptima-team": team_id,
                "x-cloptima-app": app_id,
                "x-cloptima-environment": "production",
            },
        )
        content = response.choices[0].message.content or ""
        print(f'Assistant: "{content.strip()}"')
        print(f'✓ Request admitted and attributed to team "{team_id}" and app "{app_id}".\n')
    except Exception as err:
        print(f"Attributed call failed: {err}")

    print("Review attributed spend in the Cloptima Console:")
    print(f"  - Spend Explorer: {CONSOLE['spend']}")


if __name__ == "__main__":
    main()
