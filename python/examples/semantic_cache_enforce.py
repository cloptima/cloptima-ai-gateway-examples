"""Knowledge Base & Customer Support: Real-Time Semantic Cache Enforcement

Demonstrates multi-tiered exact and semantic caching in enforce mode:
1. Exact Cache: Verbatim string matches served instantly with zero provider cost.
2. Semantic Cache: High-dimensional vector matching that intercepts paraphrased
   queries and serves cached answers without dispatching to the LLM provider.

Run standalone:
  python -m examples.semantic_cache_enforce
"""
import time
from typing import Any, Dict

from lib import gateway_admin
from lib.access import provision_app
from lib.client import openai_client
from lib.models import MODELS

ROUTE = "/v1/ai/chat/completions"
# A class approval names the model as the gateway records it: the model id
# without its provider prefix (gemini-3.5-flash-lite).
MODEL_FAMILY = MODELS["default"].split("/")[-1]


def ensure_class_approval(app_id: str) -> dict:
    return gateway_admin.admin_api(
        "POST",
        "/v1/llm/semantic-cache/class-approvals",
        body={"app_id": app_id, "route": ROUTE, "model_family": MODEL_FAMILY, "notes": "semantic-cache-enforce example"},
    )


def query_with_latency(client: Any, prompt: str, label: str) -> Dict[str, Any]:
    start = time.time()
    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            messages=[
                {"role": "system", "content": "You are an IT support assistant. Answer concisely in one sentence."},
                {"role": "user", "content": prompt},
            ],
            temperature=0.1,
        )
        duration_ms = int((time.time() - start) * 1000)
        answer = response.choices[0].message.content or ""
        return {"outcome": "success", "duration_ms": duration_ms, "answer": answer.strip(), "prompt": prompt, "label": label}
    except Exception as err:
        duration_ms = int((time.time() - start) * 1000)
        return {"outcome": "error", "duration_ms": duration_ms, "error": str(err), "prompt": prompt, "label": label}


def main() -> None:
    print("Connecting to Cloptima Gateway with Enforce-Mode Semantic Caching...")
    # Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
    # key, and binding once in the Console, Terraform, or CI.
    setup = provision_app(
        app="semantic-cache-demo",
        policy={
            "name": "semantic-cache-enforce-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
            "exact_cache_enabled": True,
            "exact_cache_mode": "enforce",
            "semantic_cache_enabled": True,
            "semantic_cache_mode": "enforce",
            "semantic_cache_review_required": True,
            "apply_immediately": True,
        },
    )
    # With semantic_cache_review_required, enforce mode serves a semantic hit only for an approved
    # (app_id, route, model_family) class. Without one, would-be hits are recorded but not served.
    ensure_class_approval(setup["app_id"])

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(setup["virtual_key"])

    # 1. Cold Request
    primary_prompt = "How do I generate a new Personal Access Token for the Cloptima API?"
    print(f'\n[Cold Query] Sending initial question: "{primary_prompt}"')
    cold = query_with_latency(client, primary_prompt, "Cold Query")
    print(f"Result: {cold['duration_ms']}ms latency | Answer: \"{cold.get('answer', '')}\"")

    # 2. Exact Cache Repeat
    print("\n[Exact Cache] Sending identical repeat query:")
    exact = query_with_latency(client, primary_prompt, "Exact Cache Hit")
    pct = 0
    if cold["duration_ms"] > 0 and exact["duration_ms"] < cold["duration_ms"]:
        pct = int(((cold["duration_ms"] - exact["duration_ms"]) / cold["duration_ms"]) * 100)
    print(f"Result: {exact['duration_ms']}ms latency ({pct}% faster)")
    print(f"Answer: \"{exact.get('answer', '')}\"")

    # 3. Semantically Paraphrased Queries
    paraphrased_prompts = [
        "Where can I create a Personal Access Token to access the Cloptima API?",
        "What are the steps to get an API personal access token in Cloptima?",
    ]

    for i, prompt in enumerate(paraphrased_prompts):
        print(f'\n[Semantic Variant {i + 1}] Sending paraphrased query: "{prompt}"')
        var_res = query_with_latency(client, prompt, f"Variant {i + 1}")
        print(f"Result: {var_res['duration_ms']}ms latency")
        print(f"Answer: \"{var_res.get('answer', '')}\"")


if __name__ == "__main__":
    main()
