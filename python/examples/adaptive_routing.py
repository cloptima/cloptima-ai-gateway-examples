"""Adaptive routing (certification/candidate contract, deterministic
routing decision, canary cohorts) configures a certified set of candidate
models per cost/latency tier under policy.metadata.routing.adaptive, a
JSON object passed as policy metadata the same way route/fallback/cache
controls are.

This scopes to 'observe' mode: the router evaluates and logs which candidate
it would have picked for each call, without actually changing where traffic
goes - actual per-call routing decisions aren't visible in this script's own
output (see the console evidence line below). Moving to 'canary' or
'enforce' additionally requires an approved_eval_id and an
approved_release_gate_id - i.e. a passed eval run (prompt_release_workflow.py)
plus a DECIDED release-gate approval - and deciding that approval is the same
kind of human-review step this repo's examples don't script (see
approval_workflow.py), so canary/enforce aren't demonstrated here.
Run standalone from python/:
    python -m examples.adaptive_routing
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT, OTHER_GEMINI_MODELS

CANDIDATE_MODELS = {
    "cheap": [OTHER_GEMINI_MODELS["gemini-2.5-flash-lite"]],
    "balanced": [MODEL_DEFAULT],
    "strong": [OTHER_GEMINI_MODELS["gemini-2.5-pro"]],
}


def main():
    suffix = config.run_suffix()
    app_id = f"adaptive-routing-{suffix}"

    print("Creating a policy with adaptive routing in observe mode across cheap/balanced/strong candidate tiers...")
    policy = create_policy({
        "name": f"adaptive-routing-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": [*CANDIDATE_MODELS["cheap"], *CANDIDATE_MODELS["balanced"], *CANDIDATE_MODELS["strong"]],
        "metadata": {
            "routing": {
                "adaptive": {
                    "mode": "observe",
                    "route_risk_ceiling": "low",
                    "candidate_set_version": f"v{suffix}",
                    "candidate_models": CANDIDATE_MODELS,
                },
            },
        },
    })
    key = create_virtual_key({"name": f"vk-adaptive-routing-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Sending a few calls at the 'balanced' tier model...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    results = []
    for i in range(3):
        result = call_openai_style(
            client, MODEL_DEFAULT, f"Routing probe {i + 1}. In one sentence, confirm this call went through.",
            {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
            f"routing-probe-{i + 1}",
        )
        results.append(result)
        print(f"  [{result['outcome']}] routing-probe-{i + 1}")

    print(
        "\nExpected: all 3 calls are served exactly as requested (observe mode never changes actual routing) - the "
        "router logs, per call, which candidate it would have picked under this certified tier set. That decision "
        "log isn't in this script's own output; it's a console-side evidence trail."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - shows the logged routing-decision trail per call; Policies tab ({config.CONSOLE['policies']}) shows the metadata.routing.adaptive config, including the candidate tiers above.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
