"""Customer Support Assistant with Personal Data (PII) Protection

Demonstrates how an application calls models through Cloptima with an active
guardrail profile, and how the application handles guardrail blocks gracefully.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Send normal user support inquiries (served normally).
3. Send inquiry containing sensitive personal data (e.g. US SSN format).
4. Catch the 403 governance block, inspect violations, and return friendly
   user-facing feedback instead of failing or leaking sensitive data.

Run standalone:
  python -m examples.pii_guardrail
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Customer Support Assistant: PII & Guardrails ===\n")

    # Governance setup: a guardrail profile that blocks credentials and US SSN formats on input,
    # attached to the policy this application runs under. Platform admins normally create these
    # once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key
    # whose policy already matches.
    access = get_access(
        app="support-bot-demo",
        guardrail_profile={
            "name": "support-guardrail-profile",
            "description": "Customer support safety profile: blocks credentials and US SSN personal data formats",
            "definition": {
                "input": {
                    "action": "block",
                    "detectors": {"secret": {}},
                    "custom_rules": [{"id": "us_ssn", "match": {"regex": r"\b\d{3}-\d{2}-\d{4}\b"}}],
                },
                "output": {"action": "observe", "detectors": {"secret": {}}},
            },
        },
        policy={
            "name": "support-guardrail-policy",
            "mode": "enforce",
            "budgetMode": "hard",
            "failMode": "fail_closed",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    # 1. Normal customer query: Allowed and processed normally
    print("--- Case 1: Standard Customer Query ---")
    clean_prompt = "I need help resetting my account password for user@example.com."
    print(f'User: "{clean_prompt}"')

    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": clean_prompt}],
        )
        content = response.choices[0].message.content or ""
        print(f"Assistant: {content.strip()}\n")
    except Exception as err:
        print(f"Unexpected error: {err}")

    # 2. Sensitive customer query containing SSN format: Blocked by Guardrail Profile
    print("--- Case 2: Query Containing Sensitive Personal Data ---")
    sensitive_prompt = "My claim reference number is associated with SSN 123-45-6789. Can you update my record?"
    print(f'User: "{sensitive_prompt}"')

    try:
        client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": sensitive_prompt}],
        )
        print("Assistant: (Processed unexpectedly)\n")
    except APIStatusError as err:
        if err.status_code == 403:
            body = err.body if isinstance(err.body, dict) else {}
            reason = body.get("reason", str(err))
            violations = body.get("violations", [])

            print("\n[Gateway Guardrail Block: HTTP 403]")
            print(f"  Reason: {reason}")
            if violations:
                print(f"  Violations detected: {', '.join(violations)}")

            # Application handles the error gracefully for the end user:
            print("\nApplication Fallback Response to End User:")
            print(
                '  "Notice: For your security, please do not include Social Security numbers or '
                'other sensitive identifiers in support requests. Please submit your request without personal identifiers."\n'
            )
        else:
            raise

    print("Evidence in Cloptima Console:")
    print(f"  - Audit trail: {CONSOLE['audit']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
