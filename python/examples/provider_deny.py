"""Provider Restriction & Data Residency Enforcement

Demonstrates how enterprise policies enforce approved provider boundaries
(e.g. Vertex AI only for data residency/compliance), and how an application
catches and recovers from unauthorized provider requests.

Pattern:
1. Policy enforces allowedProviders: ['vertex_ai'].
2. Application attempts calling an unauthorized provider (e.g. openai/gpt-4o).
3. Gateway blocks before provider egress (HTTP 403).
4. Application catches the block and falls back to an authorized model.

Run standalone:
  python -m examples.provider_deny
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Enterprise Compliance: Provider Boundary Enforcement ===\n")

    # Governance setup: a compliance policy that allows only Vertex AI. Platform admins normally
    # create it once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at
    # a key whose policy already matches.
    access = get_access(
        app="provider-boundary-demo",
        policy={
            "name": "provider-boundary-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    print('Policy active: Only "vertex_ai" is permitted.\n')

    # Case 1: Application requests an unauthorized provider
    print("--- Step 1: Requesting Unauthorized Provider (openai/gpt-4o) ---")
    fallback_needed = False

    try:
        client.chat.completions.create(
            model="openai/gpt-4o",
            messages=[{"role": "user", "content": "Process confidential compliance record."}],
        )
        print("Assistant: (Processed unexpectedly)\n")
    except APIStatusError as err:
        if err.status_code == 403:
            body = err.body if isinstance(err.body, dict) else {}
            reason = body.get("reason", str(err))
            violations = body.get("violations", [])

            print("🛡️ Gateway Compliance Block (HTTP 403)")
            print(f"  Message: {reason}")
            if violations:
                print(f"  Violations: {', '.join(violations)}")
            print("\nApplication Recovery:")
            print("  Non-compliant provider request intercepted. Automatically routing to authorized Vertex AI model...\n")
            fallback_needed = True
        else:
            raise

    # Case 2: Recovery via approved compliant model
    if fallback_needed:
        print(f"--- Step 2: Fallback to Approved Model ({MODELS['default']}) ---")
        try:
            recovery_response = client.chat.completions.create(
                model=MODELS["default"],
                messages=[{"role": "user", "content": "Process confidential compliance record."}],
            )
            content = recovery_response.choices[0].message.content or ""
            print(f'Assistant: "{content.strip()}"')
            print("✓ Workload successfully fulfilled on compliant infrastructure.\n")
        except Exception as err:
            print(f"Recovery failed: {err}")

    print("Review provider restriction audit logs in Cloptima Console:")
    print(f"  - Audit Trail: {CONSOLE['audit']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
