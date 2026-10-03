"""Create an isolated policy-bound profile for each managed guardrail scan.

Each scan is billable and requires available Cloptima managed credits.

Run standalone from python/ with:
    python -m examples.guardrail_detector_categories
"""

from lib import config
from lib.call_gateway import call_openai_style
from lib.confirm import confirm_allowed
from lib.gateway_admin import (
    create_binding,
    create_guardrail_profile,
    create_policy,
    create_virtual_key,
    graphql,
)
from lib.gateway_clients import openai_style_client
from lib.models import MODEL_DEFAULT


PROVIDERS = [
    (
        "google-model-armor",
        "Google Model Armor",
        {
            "kind": "google_model_armor",
            "credential_source": "cloptima_managed",
            "scan_directions": "input",
        },
    ),
    (
        "azure-content-safety",
        "Azure AI Content Safety",
        {
            "kind": "azure_content_safety",
            "credential_source": "cloptima_managed",
            "prompt_shields_enabled": True,
            "harm_categories": ["Hate", "Violence"],
            "scan_directions": "input",
        },
    ),
    (
        "bedrock-guardrails",
        "Amazon Bedrock Guardrails",
        {
            "kind": "bedrock_guardrails",
            "credential_source": "cloptima_managed",
            "scan_directions": "input",
        },
    ),
]


def profile_input(name: str, integration: dict) -> dict:
    return {
        "name": name,
        "description": "Managed provider scan validation example",
        "definition": {
            "input": {"action": "observe", "detectors": {"secret": {}}},
            "output": {"action": "observe", "detectors": {"secret": {}}},
            "provider_integration": integration,
        },
    }


def remove_temporary_resources(binding=None, policy=None, profile=None, key=None):
    actions = [
        (binding, "binding", "mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }"),
        (policy, "policy", "mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }"),
        (profile, "profile", "mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }"),
        (key, "key", "mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }"),
    ]
    errors = []
    for resource, label, mutation in actions:
        if not resource or not resource.get("id"):
            continue
        try:
            graphql(mutation, {"id": resource["id"]})
        except Exception as err:
            errors.append(f"{label}: {err}")
    return errors


def main():
    suffix = config.run_suffix()
    print("Creating one fail-closed profile and policy per managed scan provider...")
    print("Prerequisite: the account must have managed credits available for billable guardrail scans.")
    failures = []
    for index, (provider_id, provider_name, integration) in enumerate(PROVIDERS):
        profile = None
        policy = None
        key = None
        binding = None
        try:
            resource_name = f"guardrail-{provider_id}-{suffix}"
            app_id = resource_name
            profile = create_guardrail_profile(profile_input(resource_name, integration))
            policy = create_policy({
                "name": resource_name,
                "mode": "enforce",
                "budgetMode": "hard_fast",
                "failMode": "fail_closed",
                "allowedProviders": ["vertex_ai"],
                "allowedModels": [MODEL_DEFAULT],
                "guardrailProfileId": profile["id"],
            })
            key = create_virtual_key({
                "name": f"vk-{resource_name}",
                "teamId": "Platform AI",
                "appId": app_id,
                "environment": "dev",
            })
            binding = create_binding({
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
                "Reply with exactly: guardrail scan passed.",
                provider_name,
            )
            reason = f" ({result['reason']})" if result.get("reason") else ""
            print(f"[{result['outcome']}] {provider_name}: {result.get('status') or 'served'}{reason}")
            confirm_allowed(result, f"{provider_name} scan completed under a fail-closed policy")
            if index == len(PROVIDERS) - 1:
                print(
                    f"  retained for review - profile: {profile['id']}; "
                    f"policy: {policy['id']}; app: {app_id}"
                )
        except Exception as err:
            failures.append(f"{provider_name}: {err}")
        finally:
            if index < len(PROVIDERS) - 1:
                cleanup_errors = remove_temporary_resources(binding, policy, profile, key)
                if cleanup_errors:
                    failures.append(f"{provider_name} cleanup: {'; '.join(cleanup_errors)}")

    if failures:
        raise RuntimeError("One or more provider checks failed:\n- " + "\n- ".join(failures))
    print("\nAll three isolated managed provider scans completed successfully.")
    print(f"Review policy and request records in the console: {config.CONSOLE['policies']} and {config.CONSOLE['audit']}")


if __name__ == "__main__":
    main()
