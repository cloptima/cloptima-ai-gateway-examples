"""One policy allowlisting several Vertex AI Gemini model variants (default
flash, a cheaper flash-lite, and a higher-capability pro), mints a key, and
calls each once - the "one policy, several models, compare cost and latency"
story. These examples are built with Gemini models; bring your own
credentials for other providers/models via the byok example.

A model here can fail for two very different reasons, and this script
reports which one happened rather than treating any non-200 as the same
kind of failure:
  - policy/model block (403)  -> the model isn't allowed by this policy
  - missing pricing (402/403) -> the model is allowed, but the gateway's
    pricing catalog doesn't have a cost entry for it yet, so a spend-limited
    path fails closed. That's a pricing-catalog gap, not a sign the model
    itself is unsupported.

Run standalone from python/:
    python -m examples.multi_model
"""

import json

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT, OTHER_GEMINI_MODELS


def main():
    suffix = config.run_suffix()
    app_id = f"multi-model-{suffix}"
    models = [MODEL_DEFAULT, *OTHER_GEMINI_MODELS.values()]

    print(f"Creating policy allowlisting {len(models)} Vertex AI Gemini model variants...")
    policy = create_policy({
        "name": f"multi-model-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": models,
    })
    print(f"  policy {policy['name']} -> {policy['id']}")

    key = create_virtual_key({"name": f"vk-multi-model-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Calling each model once...\n")

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    results = []
    for model in models:
        result = call_openai_style(
            client, model,
            "In one short sentence, name the model you are.",
            {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
            model,
        )
        results.append(result)
        if result["outcome"] == "allowed":
            note = f"text=\"{(result.get('text') or '')[:80]}\""
        else:
            note = f"status={result.get('status')} reason={str(result.get('reason'))[:200]}"
        print(f"  [{result['outcome']}] {model} - {note}")

    print(
        "\nIf any model above came back blocked with a pricing-related reason rather than a policy/model-allow "
        "reason, that means the model is real and allowlisted but the gateway pricing catalog needs a cost entry "
        "for it before spend-limited calls can succeed - check the pricing catalog/overlay, not the policy."
    )
    print(f"\nEvidence: Explorer tab ({config.CONSOLE['spend']}) - filter by app \"{app_id}\" to compare cost and latency across every model called above.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
