"""Completes what exact_semantic_cache.py deliberately leaves at 'observe':
semanticCacheMode: 'enforce' needs a per-(app, route, model-family) class
approval (createLLMSemanticCacheClassApproval) on top of the policy flag,
AND setting 'enforce' on the policy itself auto-queues a separate entry in
the generic governance queue (LLMGatewayApproval, approvalType
'semantic_cache_enforce') that must be reviewed before enforcement actually
activates - until then, effective behavior stays downgraded to 'suggest'.
This script creates the policy with applyImmediately: true, so - since the
ai:admin key already qualifies to review this itself - that entry is
approved and enforcement is live immediately, with no separate review step.
See ../docs/CACHE_AND_POLICY.md.
Run standalone from python/:
    python -m examples.semantic_cache_enforce
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql, list_llm_gateway_approvals
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

ROUTE = "/v1/ai/chat/completions"
# The class approval's modelFamily must be keyed on the full canonical model
# ID (e.g. 'vertex_ai/gemini-2.5-flash'), not just its last path segment
# (e.g. 'gemini-2.5-flash') - modelFamily requires the full canonical model ID.
MODEL_FAMILY = MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    app_id = f"semantic-cache-enforce-{suffix}"

    print("Creating policy with exact cache (enforce) and semantic cache (enforce), applyImmediately: true...")
    policy = create_policy({
        "name": f"semantic-cache-enforce-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "promptRetentionMode": "full",
        "exactCacheEnabled": True, "exactCacheMode": "enforce",
        "semanticCacheEnabled": True, "semanticCacheMode": "enforce",
        "applyImmediately": True,
    })
    key = create_virtual_key({"name": f"vk-semantic-cache-enforce-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.\n")

    print(f"Requesting the class approval semantic-cache enforcement needs for (app={app_id}, route={ROUTE}, modelFamily={MODEL_FAMILY})...")
    class_approval_data = graphql(
        """mutation CreateClassApproval($input: LLMSemanticCacheClassApprovalInput!) {
          createLLMSemanticCacheClassApproval(input: $input) { id appId route modelFamily createdAt }
        }""",
        {"input": {"appId": app_id, "route": ROUTE, "modelFamily": MODEL_FAMILY, "notes": f"semantic-cache-enforce example run {suffix}"}},
    )
    print(f"  class approval granted: {json.dumps(class_approval_data['createLLMSemanticCacheClassApproval'])}")

    print("\nChecking the generic governance queue for the entry auto-queued by semanticCacheMode: 'enforce'...")
    applied = list_llm_gateway_approvals(status="applied", limit=50)
    auto_applied = next((a for a in applied if a["approvalType"] == "semantic_cache_enforce" and a["targetId"] == policy["id"]), None)
    if auto_applied:
        print(f"  applied: {json.dumps(auto_applied)}")
        print(
            "  applyImmediately: true above meant this entry was approved and applied right away, instead of sitting "
            f"pending for a second identity to review in the console's Audit tab ({config.CONSOLE['audit']})."
        )
    else:
        print("  no matching applied entry found.")

    client = openai_style_client(key["accessToken"], config.BASE_URL)

    print("\nRepeating one exact prompt 5x for exact-cache evidence (enforced immediately, no approval needed)...")
    exact_prompt = "Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month."
    exact_results = []
    for i in range(5):
        result = call_openai_style(
            client, MODEL_DEFAULT, exact_prompt,
            {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev", "x-cloptima-feature": "exact_cache_probe"},
            f"exact-cache-{i + 1}",
        )
        exact_results.append(result)
        print(f"  [{result['outcome']}] exact-cache-{i + 1}")

    print("\nSending 3 semantically similar (not identical) prompts for semantic-cache evidence...")
    semantic_prompts = [
        "In one sentence, explain why a customer running more Kubernetes pods saw higher cloud costs this month.",
        "Give a one-sentence explanation for increased cloud spend when a customer scales up their Kubernetes pod count.",
        "Why did this customer's cloud bill go up after running additional Kubernetes pods this month? One sentence.",
    ]
    semantic_results = []
    for i, prompt in enumerate(semantic_prompts):
        result = call_openai_style(
            client, MODEL_DEFAULT, prompt,
            {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev", "x-cloptima-feature": "semantic_cache_probe"},
            f"semantic-cache-{i + 1}",
        )
        semantic_results.append(result)
        print(f"  [{result['outcome']}] semantic-cache-{i + 1}")

    print(
        "\nExpected: both exact-cache and semantic-cache hits show up immediately - applyImmediately: true meant "
        "semantic-cache enforcement was live from the start, with no separate review step needed."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - shows the applied semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab ({config.CONSOLE['policies']}) shows the policy's cache config.")
    print(json.dumps({"exactResults": exact_results, "semanticResults": semantic_results}, indent=2, default=str))


if __name__ == "__main__":
    main()
