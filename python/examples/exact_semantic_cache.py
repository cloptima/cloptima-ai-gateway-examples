"""Creates a policy with exact cache enabled (enforce mode, full retention -
required to actually replay cached responses, otherwise exact cache stores
metadata-only would-hit entries) and semantic cache enabled (observe mode -
enforce mode needs an additional per-app/content-class/model-family approval
on top of the policy flag). Repeats one exact prompt for exact-cache
evidence, then sends paraphrased variants for semantic-cache evidence. There
is no client-side cache toggle - this is entirely policy-driven server-side;
see ../docs/CACHE_AND_POLICY.md.
Run standalone from python/:
    python -m examples.exact_semantic_cache
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT


def main():
    suffix = config.run_suffix()
    app_id = f"cache-demo-{suffix}"

    print("Creating policy with exact cache (enforce, full retention) and semantic cache (observe)...")
    policy = create_policy({
        "name": f"exact-semantic-cache-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "promptRetentionMode": "full",
        "exactCacheEnabled": True, "exactCacheMode": "enforce",
        "semanticCacheEnabled": True, "semanticCacheMode": "observe",
    })
    key = create_virtual_key({"name": f"vk-cache-demo-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)

    print("Repeating one exact prompt 5x for exact-cache evidence...")
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
        "\nCache hit/miss decisions show up in the console, not in this script's own output - compare latency and "
        "usage across the repeats above, then check the console for the authoritative hit/miss trail."
    )
    print(f"Evidence: Dashboard tab ({config.CONSOLE['dashboard']}) shows realized cache savings; Explorer tab ({config.CONSOLE['spend']}) shows per-request cached-token counts for the repeats above; Audit tab ({config.CONSOLE['audit']}) has the authoritative hit/miss trail.")
    print(json.dumps({"exactResults": exact_results, "semanticResults": semantic_results}, indent=2, default=str))


if __name__ == "__main__":
    main()
