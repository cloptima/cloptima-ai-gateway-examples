"""Guardrail cost-governance: guardrailCostMode, guardrailMaxCostPerRequestCents,
and guardrailCostExceededAction govern the cost of an optional heavier
provider-backed guardrail scan (guardrailProviderIntegration: webhook /
azure_content_safety / bedrock_guardrails) - downgrading to a lightweight
profile, requiring approval, or blocking when that scan would cost too much.
This example uses only the built-in pii/secret detectors, which run locally
at zero cost, so it demonstrates the cost-tuning fields being accepted
(requires the Enterprise guardrails plan) rather than the downgrade itself
firing - see guardrail_detector_categories.py for configuring a
provider-backed scan.
Run standalone from python/:
    python -m examples.guardrail_cost_governance
"""

import json

from lib import config
from lib.confirm import confirm_allowed
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. No provider-backed scan is configured
# below, so this cap is never actually exercised - it only shows the field
# being accepted.
MAX_COST_PER_REQUEST_CENTS = 1


def main():
    suffix = config.run_suffix()
    app_id = f"guardrail-cost-governance-{suffix}"

    print(f"Creating a policy with guardrailCostMode='enforce', a ${MAX_COST_PER_REQUEST_CENTS}-cent cap, and guardrailCostExceededAction='downgrade'...")
    try:
        policy = create_policy({
            "name": f"guardrail-cost-governance-{suffix}",
            "mode": "enforce", "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
            "guardrailDetectorsEnabled": ["pii", "secret"],
            "guardrailOutputAction": "redact",
            "guardrailCostMode": "enforce",
            "guardrailMaxCostPerRequestCents": MAX_COST_PER_REQUEST_CENTS,
            "guardrailRequiredRiskTier": "low",
            "guardrailCostExceededAction": "downgrade",
            "guardrailLightweightProfileEnabled": True,
        })
    except RuntimeError as err:
        print(f"  denied: {err}")
        print("Expected (non-Enterprise plan): guardrail cost-tuning fields require the Enterprise guardrails plan. Nothing further to demonstrate without it.")
        return

    key = create_virtual_key({"name": f"vk-guardrail-cost-governance-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Making a call under this policy...\n")

    # 2. Your application code - the official OpenAI SDK, unchanged.
    client = openai_style_client(key["accessToken"], config.BASE_URL)
    result = call_openai_style(
        client, MODEL_DEFAULT,
        "In one sentence, confirm this call ran under a guardrail cost-governance policy.",
        "cost-governance-probe",
    )

    # 3. What the gateway did. The cost cap only applies to a provider-backed
    # scan; pii/secret detectors are local and free, so the call is served
    # normally either way.
    print(f"[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    confirm_allowed(result, "served under a guardrail cost-governance policy")
    print(
        f"\nConfirmed: served - guardrailMaxCostPerRequestCents={MAX_COST_PER_REQUEST_CENTS} was accepted by the policy. "
        "With only local pii/secret detectors enabled, there's no provider-backed scan cost to cap here; add a "
        "guardrailProviderIntegration (see guardrail_detector_categories.py) to see the downgrade/require_approval/block "
        "action trigger."
    )
    print(f"Evidence: Policies tab ({config.CONSOLE['policies']}) shows the saved guardrailCostMode/guardrailMaxCostPerRequestCents/guardrailCostExceededAction config.")


if __name__ == "__main__":
    main()
