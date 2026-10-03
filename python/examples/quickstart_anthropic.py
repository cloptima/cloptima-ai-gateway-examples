"""Quickstart: Connecting the Anthropic SDK to Cloptima AI Gateway

Demonstrates standard Anthropic SDK integration:
1. Initialize the official Anthropic SDK with Cloptima's base URL and virtual key.
2. Send standard and streaming Messages requests through the gateway.
3. Inspect usage and request metadata.

Run standalone:
  python -m examples.quickstart_anthropic
"""
from anthropic import Anthropic

from lib.access import get_access
from lib.config import BASE_URL, CONSOLE
from lib.models import MODELS


def main() -> None:
    print("=== Cloptima AI Gateway: Anthropic SDK Quickstart ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="quickstart-demo",
        policy={
            "name": "quickstart-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = Anthropic(
        api_key=access["virtual_key"],
        base_url=BASE_URL,  # the SDK appends /v1/messages
    )

    # 1. Standard Messages API Call
    print("--- 1. Standard Messages API Request ---")
    response = client.messages.create(
        model=MODELS["default"],
        max_tokens=300,
        messages=[
            {"role": "user", "content": "What are the main benefits of centralized LLM gateway governance?"},
        ],
    )

    text = ""
    for block in response.content:
        if hasattr(block, "text"):
            text += block.text
    print(f"Assistant:\n  {text.strip()}\n")
    if response.usage:
        print(f"Tokens: {response.usage.input_tokens} input, {response.usage.output_tokens} output")
    print(f"Request ID: {response.id}\n")

    # 2. Streaming Messages Call
    print("--- 2. Streaming Messages Request ---")
    print("Assistant: ", end="", flush=True)
    with client.messages.stream(
        model=MODELS["default"],
        max_tokens=100,
        messages=[{"role": "user", "content": "List 3 cloud cost best practices briefly."}],
    ) as stream:
        for delta in stream.text_stream:
            print(delta, end="", flush=True)
    print("\n")

    print(f"View live spend, latency, and attribution in the console: {CONSOLE['spend']}")


if __name__ == "__main__":
    main()
