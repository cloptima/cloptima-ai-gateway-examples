"""Customer Support Assistant with Personal Data (PII) Protection

Demonstrates how an application calls models through Cloptima with a guardrail
profile that protects personal data, and how the application handles a guardrail block.

Pattern:
1. Governance setup: a guardrail profile that redacts US personal data (the
   us_personal_data template) and blocks employee IDs (a custom employee_id rule).
2. Case 1: A message with an email address and a phone number is answered. The model
   provider sees placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of the values,
   and the gateway restores the values in the response, so the application gets its own
   data back.
3. Case 2: A message with an employee ID is refused before it reaches the model (HTTP 403).
   The application reads the block reason and returns a friendly message.

Prerequisite: custom rules and every template except secrets need the
llm_guardrail_enterprise entitlement.

Run standalone:
  python -m examples.pii_guardrail
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

CUSTOMER_EMAIL = "jane.doe@example.com"
CUSTOMER_PHONE = "415-555-0142"


def main() -> None:
    print("=== Customer Support Assistant: PII & Guardrails ===\n")

    # Governance setup: a guardrail profile attached to the policy this application runs under.
    # Platform admins normally create these once in the Console, Terraform, or CI. Skipped when
    # CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
    access = get_access(
        app="support-bot-demo",
        guardrail_profile={
            "name": "support-guardrail-profile",
            "description": "Customer support: redact US personal data, block employee IDs",
            "definition": {
                "protect": [
                    # Latest version of the template; add "version" to pin one.
                    {"template": "us_personal_data", "action": "redact"},
                    # Matches a value such as "Employee ID: E482913" (the label ignores case).
                    {"rule": "employee_id", "match": {"label": "(?i:employee id)", "value": r"E\d{6}"}, "action": "block"},
                ],
            },
        },
        policy={
            "name": "support-guardrail-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "fail_mode": "fail_closed",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    # Case 1: personal data is redacted for the provider and restored for the application.
    print("--- Case 1: Query Containing an Email Address and Phone Number ---")
    contact_prompt = (
        f"I can't sign in. My account email is {CUSTOMER_EMAIL} and my phone is {CUSTOMER_PHONE}. "
        "Repeat my contact details back to me, then tell me the next step."
    )
    print(f'User: "{contact_prompt}"')

    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": contact_prompt}],
        )
        reply = (response.choices[0].message.content or "").strip()
        print(f"Assistant: {reply}\n")
        print("The model provider received placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of")
        print("the email address and phone number. The gateway restored the values in the response.")
        if CUSTOMER_EMAIL in reply or CUSTOMER_PHONE in reply:
            print("✓ The answer shows the customer's own contact details.")
        print()
    except Exception as err:
        print(f"Unexpected error: {err}")

    # Case 2: a block rule refuses the request before it reaches the model.
    print("--- Case 2: Query Containing an Employee ID ---")
    employee_prompt = "Please apply my staff discount to order 1042. My Employee ID: E482913."
    print(f'User: "{employee_prompt}"')

    try:
        client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": employee_prompt}],
        )
        print("Assistant: (Processed unexpectedly)\n")
    except APIStatusError as err:
        if err.status_code == 403:
            # The gateway's block body: {"error": "<message>", "reason": "gateway_guardrail_blocked", "violations": [...]}.
            # A custom rule's violation is custom_<rule id>, here custom_employee_id.
            body = err.body if isinstance(err.body, dict) else {}
            print("\n[Gateway Guardrail Block: HTTP 403]")
            print(f"  Reason: {body.get('reason') or 'unknown'}")
            print(f"  Message: {body.get('message') or err.message}")
            violations = body.get("violations") or []
            if violations:
                print(f"  Violations: {', '.join(violations)}")

            # Application handles the error gracefully for the end user:
            print("\nApplication Fallback Response to End User:")
            print(
                '  "Notice: For your security, please do not include employee IDs in support requests. '
                'Please submit your request without internal identifiers."\n'
            )
        else:
            raise

    print("Evidence in Cloptima Console:")
    print(f"  - Guardrail profiles: {CONSOLE['guardrails']}")
    print(f"  - Audit trail: {CONSOLE['audit']}")


if __name__ == "__main__":
    main()
