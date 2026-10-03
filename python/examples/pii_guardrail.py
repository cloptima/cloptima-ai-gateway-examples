"""Use a profile custom rule to block a fictional SSN format.

Run standalone from python/ with:
    python -m examples.pii_guardrail
"""

from lib import config
from lib.confirm import confirm_blocked
from lib.gateway_admin import create_binding, create_guardrail_profile, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    app_id = f"pii-guardrail-{suffix}"
    profile = create_guardrail_profile({
        "name": f"pii-guardrail-{suffix}",
        "description": "Block credentials and configured personal-data formats",
        "definition": {
            "input": {
                "action": "block",
                "detectors": {"secret": {}},
                "custom_rules": [{"id": "us_ssn", "match": {"regex": r"\b\d{3}-\d{2}-\d{4}\b"}}],
            },
            "output": {"action": "observe", "detectors": {"secret": {}}},
        },
    })
    policy = create_policy({
        "name": f"pii-guardrail-{suffix}",
        "mode": "enforce",
        "budgetMode": "hard_fast",
        "failMode": "fail_closed",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": [MODEL_DEFAULT],
        "guardrailProfileId": profile["id"],
    })
    key = create_virtual_key({
        "name": f"vk-pii-guardrail-{suffix}",
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
        "This fictional QA record contains SSN 123-45-6789. Summarize it.",
        "pii-format-rule-probe",
    )
    print(f"[{result['outcome']}] {result}")
    confirm_blocked(result, "profile custom rule for a US SSN", status=403)
    print("\nConfirmed: the profile rule blocked the matching input before model egress.")
    print(f"Profile: {profile['id']}; policy: {policy['id']}; review them in {config.CONSOLE['policies']} and {config.CONSOLE['audit']}")


if __name__ == "__main__":
    main()
