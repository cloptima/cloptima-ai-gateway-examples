"""Multi-Model Gateway: Switching and Comparing Models

Demonstrates how a single Cloptima virtual key and standard OpenAI client
can seamlessly dispatch across different model tiers under one unified policy.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Dispatch identical prompts to multiple model tiers (e.g. Flash Lite vs Flash).
3. Compare latency, token consumption, and response quality.

Run standalone:
  python -m examples.multi_model
"""
import time

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Multi-Model Gateway: Unified Model Comparison ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="multi-model-demo",
        policy={
            "name": "multi-model-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"], MODELS["premium"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    models_to_compare = [MODELS["default"], MODELS["premium"]]
    test_prompt = "Explain the difference between vertical and horizontal autoscaling in 2 sentences."
    print(f'Evaluating prompt across {len(models_to_compare)} models:\n"{test_prompt}"\n')

    for model in models_to_compare:
        print(f"--- Model: {model} ---")
        start = time.time()

        try:
            completion = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": test_prompt}],
            )
            elapsed_ms = int((time.time() - start) * 1000)
            content = completion.choices[0].message.content or ""
            usage = completion.usage

            print(f"Assistant: {content.strip()}")
            if usage:
                print(f"Metrics: {elapsed_ms}ms latency | {usage.total_tokens} tokens ({usage.prompt_tokens} in / {usage.completion_tokens} out)\n")
        except Exception as err:
            print(f"Error calling {model}: {err}\n")

    print("Compare aggregate cost and latency per model in the Cloptima Console:")
    print(f"  - Explorer: {CONSOLE['spend']}")
    print(f"  - Recommendations: {CONSOLE['recommendations']}")


if __name__ == "__main__":
    main()
