"""Creates a policy requiring attribution metadata, but mints its virtual key
deliberately WITHOUT team/app/environment and binds it by principalId
instead - the only way to produce a genuine missing-attribution block, since
a key with baked-in team/app/environment is trusted as an attribution
fallback when headers are absent. Calling with zero headers on this
deliberately unscoped key trips a more fundamental gate before the policy's
own required-metadata check ever runs.
Run standalone from python/:
    python -m examples.metadata_deny
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()

    print("Creating a policy that requires team_id/app_id/environment metadata...")
    policy = create_policy({
        "name": f"metadata-deny-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "metadata": {"required_metadata_keys": ["team_id", "app_id", "environment"]},
    })

    print("Minting a key with NO team/app/environment on purpose...")
    key = create_virtual_key({"name": f"vk-metadata-deny-{suffix}"})

    print("Binding by the key's own principalId (not team/app/environment)...")
    # A principalId-only binding has no team/app/environment to distinguish its
    # scope, so it always overlaps every other binding in the org - acknowledging
    # that is required, not optional here.
    create_binding({"policyId": policy["id"], "principalId": key["id"], "actorType": "service", "priority": 5, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Calling with zero attribution headers...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    result = call_openai_style(
        client, MODEL_DEFAULT,
        "This call should be denied - the key is deliberately unscoped and no attribution metadata is sent.",
        {},
        "metadata-deny-probe",
    )

    print(f"[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    print(
        '\nExpected: 400 - "Managed AI requests require Cloptima team and app attribution" - a more basic gate '
        "than the policy engine's own required_metadata_keys check, but a genuine block either way."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - filter by key {key['id']} for the missing-attribution block record.")


if __name__ == "__main__":
    main()
