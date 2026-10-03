"""Guardrail Cost Governance: Managed Provider Scan Cost Capping

Demonstrates how to configure a per-request cost cap on provider-backed guardrail
scans (e.g. Google Model Armor) to protect against unexpected security scanning costs.

Prerequisite:
- Requires available Cloptima managed credits because external provider scans are billable.

Run standalone:
  python -m examples.guardrail_cost_governance
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

MAX_COST_PER_REQUEST_CENTS = 1


def main() -> None:
    print("=== Guardrail Cost Governance: Per-Request Scan Cap ===\n")
    print("Prerequisite: The account must have managed credits available for billable guardrail scans.\n")

    # Governance setup: a guardrail profile with a managed Model Armor scan and a per-request cost cap,
    # attached to the policy this application runs under. Platform admins normally create these once
    # in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key whose policy
    # already matches.
    print(f"Configuring guardrail profile with Google Model Armor and a {MAX_COST_PER_REQUEST_CENTS}¢ cap...")
    access = get_access(
        app="guardrail-cost-demo",
        guardrail_profile={
            "name": "guardrail-cost-profile",
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
        },
        policy={
            "name": "guardrail-cost-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "failMode": "fail_closed",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    print("Sending user prompt through guarded route...")
    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "Confirm this request passed safety scan within cost budget."}],
        )
        content = response.choices[0].message.content or ""
        print(f'Assistant: "{content.strip()}"')
        print(f"Scan outcome: Admitted and served within the {MAX_COST_PER_REQUEST_CENTS}¢ budget cap.")
    except APIStatusError as err:
        if err.status_code == 403:
            print(f"🛑 Scan Cost Exceeded Cap (HTTP 403): {err}")
        else:
            print(f"Request error: {err}")
    except Exception as err:
        print(f"Request error: {err}")

    print("\nReview guardrail scan ledger and policies in Cloptima Console:")
    print(f"  - Guardrail Scan Ledger: {CONSOLE['audit']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
