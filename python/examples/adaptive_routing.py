"""Adaptive Routing: Tiered Model Optimization

Demonstrates how Cloptima policies configure candidate model tiers
(cheap, balanced, strong) to dynamically evaluate routing options and optimize
cost-to-performance tradeoffs.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Send requests through the policy configured with candidate model tiers.
3. Inspect routing metadata and recommendations in the Cloptima Console.

Run standalone:
  python -m examples.adaptive_routing
"""
from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

CANDIDATE_MODELS = {
    "cheap": [MODELS["default"]],
    "balanced": [MODELS["default"]],
    "strong": [MODELS["premium"]],
}


def main() -> None:
    print("=== Adaptive Routing: Cost & Performance Optimization ===\n")

    # Governance setup: a policy with candidate model tiers for adaptive routing in observe mode.
    # Platform admins normally create it once in the Console, Terraform, or CI. Skipped when
    # CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
    all_models = list({m for tier in CANDIDATE_MODELS.values() for m in tier})
    access = get_access(
        app="adaptive-routing-demo",
        policy={
            "name": "adaptive-routing-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": all_models,
            "metadata": {
                "routing": {
                    "adaptive": {
                        "mode": "observe",
                        "route_risk_ceiling": "low",
                        "candidate_set_version": "v1",
                        "candidate_models": CANDIDATE_MODELS,
                    },
                },
            },
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    tasks = [
        {"label": "Routine Data Extraction", "prompt": 'Extract city and temperature from: "It is 22C in London today".'},
        {"label": "Complex Synthesis", "prompt": "Summarize the CAP theorem and its impact on distributed consensus in 2 sentences."},
    ]

    for i, task in enumerate(tasks):
        print(f"[Request {i + 1}: {task['label']}]")
        print(f'Prompt: "{task["prompt"]}"')

        try:
            response = client.chat.completions.create(
                model=MODELS["default"],
                messages=[{"role": "user", "content": task["prompt"]}],
            )
            content = response.choices[0].message.content or ""
            tokens = response.usage.total_tokens if response.usage else 0
            print(f'Assistant: "{content.strip()}"')
            print(f"Usage: {tokens} tokens | Request ID: {response.id}\n")
        except Exception as err:
            print(f"Request failed: {err}\n")

    print("Review adaptive routing recommendations and candidates in the Cloptima Console:")
    print(f"  - Recommendations & Routing: {CONSOLE['recommendations']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
