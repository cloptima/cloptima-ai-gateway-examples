"""Set a per-request scan cost cap in a provider-backed guardrail profile.

The billable managed scan requires available Cloptima managed credits.

Run standalone from python/ with:
    python -m examples.guardrail_cost_governance
"""

from lib import config
from lib.confirm import confirm_allowed
from lib.gateway_admin import create_binding, create_guardrail_profile, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


MAX_COST_PER_REQUEST_CENTS = 1


def main():
    suffix = config.run_suffix()
    app_id = f"guardrail-cost-governance-{suffix}"
    print("Prerequisite: the account must have managed credits available for this billable guardrail scan.")
    profile = create_guardrail_profile({
        "name": f"guardrail-cost-governance-{suffix}",
        "description": "Managed Model Armor scan with a per-request cost cap",
        "definition": {
            "input": {"action": "observe", "detectors": {"secret": {}}},
            "output": {"action": "observe", "detectors": {"secret": {}}},
            "provider_integration": {
                "kind": "google_model_armor",
                "credential_source": "cloptima_managed",
                "scan_directions": "input",
            },
            "cost": {
                "mode": "enforce",
                "max_cost_per_request_cents": MAX_COST_PER_REQUEST_CENTS,
                "exceeded_action": "block",
            },
        },
    })
    policy = create_policy({
        "name": f"guardrail-cost-governance-{suffix}",
        "mode": "enforce",
        "budgetMode": "hard_fast",
        "failMode": "fail_closed",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": [MODEL_DEFAULT],
        "guardrailProfileId": profile["id"],
    })
    key = create_virtual_key({
        "name": f"vk-guardrail-cost-governance-{suffix}",
        "teamId": "Platform AI",
        "appId": app_id,
        "environment": "dev",
    })
    create_binding({
        "policyId": policy["id"],
        "teamId": "Platform AI",
        "appId": app_id,
        "environment": "dev",
        "priority": 10,
        "acknowledgeOverlap": True,
    })

    result = call_openai_style(
        openai_style_client(key["accessToken"], config.BASE_URL),
        MODEL_DEFAULT,
        "Reply with exactly: scan cost is within the configured cap.",
        "cost-governance-probe",
    )
    print(f"[{result['outcome']}] {result}")
    confirm_allowed(result, "provider scan stayed within the configured cost cap")
    print(f"\nConfirmed: the profile's {MAX_COST_PER_REQUEST_CENTS}-cent cap admitted this scan.")
    print(f"Profile: {profile['id']}; policy: {policy['id']}; review them in {config.CONSOLE['policies']} and {config.CONSOLE['audit']}")


if __name__ == "__main__":
    main()
