"""Two-step scenario, deliberately not a hardcoded "here's some fake PII"
string: a hardcoded test string invites the fair objection "of course your
detector matches its own fixture." Instead:
  1. Ask the model itself, through an unguarded key, to invent a short
     fictional support ticket containing fake PII. Nobody wrote this text;
     the model generates it live, moments before step 2.
  2. Feed that freshly-generated text through a second key bound to a
     PII/secret guardrail policy. The guardrail has to detect content it
     has never seen before.
Run standalone from python/:
    python -m examples.pii_guardrail
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    generator_app_id = f"pii-guardrail-generator-{suffix}"
    guarded_app_id = f"pii-guardrail-{suffix}"

    print("Creating an unguarded policy (to generate the fixture) and a guardrail-enforced policy...")
    generator_policy = create_policy({
        "name": f"pii-guardrail-generator-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
    })
    guarded_policy = create_policy({
        "name": f"pii-guardrail-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "guardrailDetectorsEnabled": ["pii", "secret"],
        "guardrailOutputAction": "redact",
    })

    generator_key = create_virtual_key({
        "name": f"vk-pii-generator-{suffix}", "teamId": "Platform AI", "appId": generator_app_id, "environment": "dev",
    })
    guarded_key = create_virtual_key({
        "name": f"vk-pii-guardrail-{suffix}", "teamId": "Platform AI", "appId": guarded_app_id, "environment": "dev",
    })
    create_binding({"policyId": generator_policy["id"], "teamId": "Platform AI", "appId": generator_app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    create_binding({"policyId": guarded_policy["id"], "teamId": "Platform AI", "appId": guarded_app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print("Minted both keys, bound. Generating a fictional PII-bearing ticket live...\n")

    generator_client = openai_style_client(generator_key["accessToken"], config.BASE_URL)
    generation = call_openai_style(
        generator_client, MODEL_DEFAULT,
        "Generate a short, entirely fictional customer support ticket transcript for a QA test. "
        "Include a clearly fake SSN in XXX-XX-XXXX format, a fake 16-digit credit card number, a fake email "
        "address, and a fake phone number - all obviously placeholder values, never real. Output only the ticket text.",
        {"x-cloptima-team": "Platform AI", "x-cloptima-app": generator_app_id, "x-cloptima-environment": "dev"},
        "generate-fixture",
    )
    generated_text = generation.get("text") or ""
    print(f"Generated ticket (fed into the guardrail-enforced call below):\n  {generated_text.replace(chr(10), chr(10) + '  ')}\n")

    guarded_client = openai_style_client(guarded_key["accessToken"], config.BASE_URL)
    guarded = call_openai_style(
        guarded_client, MODEL_DEFAULT,
        f"A customer submitted this support ticket. Draft a one-sentence acknowledgement reply.\n\n{generated_text}",
        {"x-cloptima-team": "Platform AI", "x-cloptima-app": guarded_app_id, "x-cloptima-environment": "dev"},
        "pii-guardrail-probe",
    )

    print(f"[{guarded['outcome']}] {json.dumps(guarded, indent=2, default=str)}")
    print(
        "\nExpected: blocked before provider egress (403, detector_pii) - prompt-side PII is denied, not silently "
        "admitted. guardrailOutputAction: redact applies to generated output, not an incoming sensitive prompt."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - the block record names the pii/secret detector that fired; Policies tab ({config.CONSOLE['policies']}) shows the guardrailDetectorsEnabled config.")


if __name__ == "__main__":
    main()
