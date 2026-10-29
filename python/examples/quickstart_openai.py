"""Quickstart: Connecting the OpenAI SDK to Cloptima AI Gateway

Demonstrates standard client integration:
1. Initialize the official OpenAI SDK with Cloptima's base URL and virtual key.
2. Send standard and streaming chat completion requests.
3. Inspect request attribution and token usage.

Run standalone:
  python -m examples.quickstart_openai
"""
from openai import OpenAI

from lib.access import get_access
from lib.config import BASE_URL, CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Cloptima AI Gateway: OpenAI SDK Quickstart ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="quickstart-demo",
        policy={
            "name": "quickstart-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": ["vertex_ai"],
            "allowed_models": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    # Tip: In production services where you want to inspect policy/guardrail block details
    # (such as err.body["violations"] and err.body["reason"]), use the client helper from
    # lib/client.py which preserves these gateway fields on raised SDK errors.
    client = OpenAI(
        api_key=access["virtual_key"],
        base_url=f"{BASE_URL}/v1/ai",  # the SDK appends /chat/completions
    )

    # 1. Standard Chat Completion
    print("--- 1. Standard Chat Completion ---")
    completion = client.chat.completions.create(
        model=MODELS["default"],
        messages=[
            {"role": "system", "content": "You are a helpful cloud engineer."},
            {"role": "user", "content": "Explain what an AI gateway does in one clear sentence."},
        ],
    )

    content = completion.choices[0].message.content or ""
    print(f"Assistant: {content.strip()}")
    if completion.usage:
        print(f"Tokens: {completion.usage.total_tokens} (prompt: {completion.usage.prompt_tokens}, completion: {completion.usage.completion_tokens})")
    print(f"Request ID: {completion.id}\n")

    # 2. Streaming Chat Completion
    print("--- 2. Streaming Chat Completion ---")
    stream = client.chat.completions.create(
        model=MODELS["default"],
        messages=[{"role": "user", "content": "Count from 1 to 5 with commas."}],
        stream=True,
    )

    print("Assistant: ", end="", flush=True)
    for chunk in stream:
        delta = chunk.choices[0].delta.content if chunk.choices else ""
        if delta:
            print(delta, end="", flush=True)
    print("\n")

    print(f"View live spend, latency, and attribution in the console: {CONSOLE['spend']}")


if __name__ == "__main__":
    main()
