"""Guardrail cost-governance: guardrailCostMode governs whether the gateway
will run a heavier (and costlier) provider-backed detector scan per request,
and guardrailCostExceededAction decides what happens when that scan's cost
would exceed guardrailMaxCostPerRequestCents. Deliberately pins a tiny cost
cap (mirrors budget_limit.py's "pin a small threshold to keep the knob
meaningful" pattern) so cost-exceeded behavior triggers deterministically,
then enables guardrailLightweightProfileEnabled so 'downgrade' has a cheaper
profile to fall back to instead of failing closed. All cost-tuning fields are
Enterprise-gated (llm_guardrail_enterprise), so this is wrapped in try/except
to show that gate too on a non-Enterprise customer.
Run standalone from python/:
    python -m examples.guardrail_cost_governance
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# Illustrative, not a platform minimum. Deliberately tiny so any heavier
# provider-backed scan exceeds it and the cost-exceeded action is exercised.
MAX_COST_PER_REQUEST_CENTS = 1


def main():
    suffix = config.run_suffix()
    app_id = f"guardrail-cost-governance-{suffix}"

    print(f"Creating a policy with guardrailCostMode='enforce', a ${MAX_COST_PER_REQUEST_CENTS}-cent cap, and downgrade-to-lightweight on exceed...")
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
        print("Expected (non-Enterprise customer): guardrail cost-tuning fields require the llm_guardrail_enterprise entitlement. Nothing further to demonstrate without it.")
        return

    key = create_virtual_key({"name": f"vk-guardrail-cost-governance-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Making a call that should trip the cost-exceeded downgrade...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    result = call_openai_style(
        client, MODEL_DEFAULT,
        "In one sentence, confirm this call ran under a guardrail cost-governance policy.",
        {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
        "cost-governance-probe",
    )

    print(f"[{result['outcome']}] {json.dumps(result, indent=2, default=str)}")
    print(
        f"\nExpected: allowed - the {MAX_COST_PER_REQUEST_CENTS}-cent cap is exceeded by the full detector scan, so the "
        "request is served via the cheaper guardrailLightweightProfileEnabled fallback rather than blocked outright "
        "(guardrailCostExceededAction: 'downgrade'). Re-run with guardrailCostExceededAction: 'block' to see the deny "
        "path instead, or 'require_approval' to route it through the LLMGatewayApproval governance queue."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - the record shows the cost-exceeded downgrade decision; Dashboard tab ({config.CONSOLE['dashboard']}) surfaces guardrailCostUsd/guardrailAvoidedCostUsd.")


if __name__ == "__main__":
    main()
