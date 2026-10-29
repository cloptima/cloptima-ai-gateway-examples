"""Knowledge Base & FAQ Retrieval with Exact and Semantic Caching

Demonstrates how Cloptima's caching layer reduces latency and eliminates model
token costs on repeated or semantically similar queries.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Query 1: Initial user query (Cache Miss) -> routed to model, normal latency.
3. Query 2: Identical query (Exact Cache Hit) -> served instantly from gateway cache at 0 token cost.
4. Query 3: Paraphrased queries -> evaluated by the gateway's semantic cache engine.

Run standalone:
  python -m examples.exact_semantic_cache
"""
import time
from typing import Any, Dict

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def timed_completion(client: Any, prompt: str, label: str) -> Dict[str, Any]:
    start = time.time()
    response = client.chat.completions.create(
        model=MODELS["default"],
        messages=[{"role": "user", "content": prompt}],
    )
    elapsed_ms = int((time.time() - start) * 1000)
    content = response.choices[0].message.content or ""
    return {
        "label": label,
        "elapsed_ms": elapsed_ms,
        "content": content.strip(),
        "usage": response.usage,
        "id": response.id,
    }


def main() -> None:
    print("=== FAQ & Knowledge Search: Exact & Semantic Caching ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="knowledge-cache-demo",
        policy={
            "name": "knowledge-cache-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
            "exact_cache_enabled": True,
            "exact_cache_mode": "enforce",
            "exact_cache_ttl_seconds": 3600,
            "semantic_cache_enabled": True,
            "semantic_cache_mode": "observe",
            "semantic_cache_similarity_threshold": 0.85,
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    # 1. Query 1: Initial query (Cache Miss)
    query = "How do I configure automatic database backups in Kubernetes?"
    print("--- Query 1: Initial Request (Cold Miss) ---")
    print(f'User: "{query}"')

    initial = timed_completion(client, query, "Initial Call")
    print(f"Assistant: {initial['content']}")
    tokens = initial["usage"].total_tokens if initial["usage"] else 0
    print(f"Latency: {initial['elapsed_ms']}ms | Tokens: {tokens}\n")

    # Allow cache write to settle in background
    time.sleep(1.5)

    # 2. Query 2: Repeated identical query (Exact Cache Hit)
    print("--- Query 2: Repeated Identical Request (Exact Cache Hit) ---")
    print(f'User: "{query}"')

    cached = timed_completion(client, query, "Cached Call")
    print(f"Assistant: {cached['content']}")
    cached_tokens = cached["usage"].total_tokens if cached["usage"] else 0
    print(f"Latency: {cached['elapsed_ms']}ms (vs {initial['elapsed_ms']}ms initial) | Tokens: {cached_tokens}\n")

    if cached["elapsed_ms"] < initial["elapsed_ms"]:
        pct = int(((initial["elapsed_ms"] - cached["elapsed_ms"]) / initial["elapsed_ms"]) * 100)
        print(f"⚡ Performance improvement: ~{pct}% latency reduction via gateway cache.\n")

    # 3. Query 3: Semantically similar paraphrased variants
    print("--- Query 3: Semantically Similar Paraphrased Queries ---")
    paraphrased_variants = [
        "What is the procedure for setting up automated K8s DB backups?",
        "How can I automate database backups inside a Kubernetes cluster?",
    ]

    for index, variant in enumerate(paraphrased_variants):
        print(f'Variant {index + 1}: "{variant}"')
        res = timed_completion(client, variant, f"Variant {index + 1}")
        print(f"  Latency: {res['elapsed_ms']}ms\n")

    print("Evidence in Cloptima Console:")
    print(f"  - Cache performance & savings: {CONSOLE['spend']}")
    print(f"  - Policies & cache configuration: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
