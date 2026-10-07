"""Multi-Provider Managed Guardrail Evaluation

Demonstrates integrating managed third-party guardrail providers
(Google Model Armor, Azure AI Content Safety, Amazon Bedrock Guardrails) through
Cloptima-managed credentials.

Prerequisite:
- Requires available Cloptima managed credits because external provider scans are billable.

Run standalone:
  python -m examples.guardrail_detector_categories
Choose a provider with GUARDRAIL_PROVIDER (default google-model-armor):
  GUARDRAIL_PROVIDER=azure-content-safety python -m examples.guardrail_detector_categories
  GUARDRAIL_PROVIDER=bedrock-guardrails python -m examples.guardrail_detector_categories
"""
import os

from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

PROVIDERS = {
    "google-model-armor": {
        "id": "google-model-armor",
        "name": "Google Model Armor",
        "integration": {
            "kind": "google_model_armor",
            "credential_source": "cloptima_managed",
            "scan_directions": "input",
        },
    },
    "azure-content-safety": {
        "id": "azure-content-safety",
        "name": "Azure AI Content Safety",
        "integration": {
            "kind": "azure_content_safety",
            "credential_source": "cloptima_managed",
            "prompt_shields_enabled": True,
            "harm_categories": ["Hate", "Violence"],
            "scan_directions": "input",
        },
    },
    "bedrock-guardrails": {
        "id": "bedrock-guardrails",
        "name": "Amazon Bedrock Guardrails",
        "integration": {
            "kind": "bedrock_guardrails",
            "credential_source": "cloptima_managed",
            "scan_directions": "input",
        },
    },
}


def profile_input(name: str, integration: dict) -> dict:
    return {
        "name": name,
        "description": "Managed provider scan integration example",
        "definition": {
            "input": {"action": "observe", "detectors": {"secret": {}}},
            "output": {"action": "observe", "detectors": {"secret": {}}},
            "provider_integration": integration,
        },
    }


def main() -> None:
    print("=== Multi-Provider Managed Guardrail Evaluation ===\n")
    print("Prerequisite: The account must have managed credits available for billable guardrail scans.\n")

    selected_key = os.environ.get("GUARDRAIL_PROVIDER", "google-model-armor")
    provider = PROVIDERS.get(selected_key)
    if provider is None:
        raise RuntimeError(f'Unknown GUARDRAIL_PROVIDER "{selected_key}". Use one of: {", ".join(PROVIDERS)}.')
    print(f"Active Provider Integration: {provider['name']}")

    # Governance setup: a guardrail profile with the selected managed provider scan attached
    # to the policy this application runs under. Skipped when CLOPTIMA_VIRTUAL_KEY is set.
    access = get_access(
        app=f"guardrail-{provider['id']}-demo",
        guardrail_profile=profile_input(f"guardrail-{provider['id']}-profile", provider["integration"]),
        policy={
            "name": f"guardrail-{provider['id']}-policy",
            "mode": "enforce",
            "budgetMode": "hard",
            "failMode": "fail_closed",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )

    client = openai_client(access["virtual_key"])

    print("\nSending request through guarded route (pre-flight scan active)...")
    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "Confirm this request passed safety scan."}],
        )

        content = response.choices[0].message.content or ""
        tokens = response.usage.total_tokens if response.usage else 0
        print(f'  ✓ Scan completed & response served: "{content.strip()}"')
        print(f"  Tokens: {tokens} | Request ID: {response.id}")
    except APIStatusError as err:
        if err.status_code == 403:
            body = err.body if isinstance(err.body, dict) else {}
            reason = body.get("reason", str(err))
            violations = body.get("violations", [])
            print("  🛡️ Gateway Security Block (HTTP 403)")
            print(f"  Reason: {reason}")
            print(f"  Violations: {', '.join(violations)}")
        else:
            print(f"  Request error: {err}")
    except Exception as err:
        print(f"  Request error: {err}")

    print("\nReview guardrail scan events in the Cloptima Console:")
    print(f"  - Audit Trail: {CONSOLE['audit']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
