"""Summarization Service with Output Token Boundaries

Demonstrates how Cloptima policies prevent runaway output generation
and protect against compute cost overruns pre-flight.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Case 1: Concise summary within token bounds -> admitted and generated.
3. Case 2: Oversized generation violating max_output_tokens cap -> blocked pre-flight.
4. Application catches the token boundary error and informs the caller.

Run standalone:
  python -m examples.token_limit
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Summarization Service: Output Token Boundaries ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="token-limit-demo",
        policy={
            "name": "token-limit-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
            "max_output_tokens": 100,  # the minimum allowed value is 64
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    # 1. Case 1: Concise request within bounds
    print("--- Case 1: Concise Summary (Within Token Cap) ---")
    try:
        response = client.chat.completions.create(
            model=MODELS["default"],
            max_tokens=30,
            messages=[{"role": "user", "content": "Summarize the concept of API gateways in 10 words."}],
        )
        content = response.choices[0].message.content or ""
        print(f'Assistant: "{content.strip()}"')
        tokens = response.usage.completion_tokens if response.usage else 0
        print(f"Tokens used: {tokens}\n")
    except Exception as err:
        print(f"Unexpected error on valid token call: {err}")

    # 2. Case 2: Excessive generation exceeding policy limit
    print("--- Case 2: Unbounded Generation (Exceeding Policy Limit) ---")
    oversized_prompt = "Write a comprehensive 500-word analysis on distributed microservice architectures."
    print(f'User: "{oversized_prompt}"')

    try:
        client.chat.completions.create(
            model=MODELS["default"],
            # Requesting 500 tokens exceeds the policy's max_output_tokens cap of 100
            max_tokens=500,
            messages=[{"role": "user", "content": oversized_prompt}],
        )
        print("Assistant: (Generated unexpectedly)\n")
    except APIStatusError as err:
        if err.status_code == 403:
            body = err.body if isinstance(err.body, dict) else {}
            reason = body.get("message", str(err))
            violations = body.get("violations", [])

            print("🛑 [Pre-flight Token Block: HTTP 403]")
            print(f"  Message: {reason}")
            if violations:
                print(f"  Violations: {', '.join(violations)}")

            print("\nApplication Fallback Action:")
            print("  Request rejected pre-flight before incurring compute costs.")
            print('  Notice to client: "Please request a concise summary (under 100 tokens) or adjust your policy quota."\n')
        else:
            raise

    print("Review token limit policies in the Cloptima Console:")
    print(f"  - Audit Trail: {CONSOLE['audit']}")
    print(f"  - Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
