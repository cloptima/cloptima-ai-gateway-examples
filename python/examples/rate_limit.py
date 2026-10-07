"""Resilient Batch Worker: Rate Limit Handling & Backoff

Demonstrates how client applications handle rate limits (HTTP 429) enforced
by Cloptima policies using standard retry and exponential backoff patterns.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Process a series of tasks.
3. When rate limits are tripped (HTTP 429), catch the error, back off, and retry.

Run standalone:
  python -m examples.rate_limit
"""
import time
from typing import Any, Dict

from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS


def execute_with_retry(client: Any, task_prompt: str, max_retries: int = 3) -> Dict[str, Any]:
    attempt = 0
    delay_s = 1.0

    while attempt <= max_retries:
        try:
            completion = client.chat.completions.create(
                model=MODELS["default"],
                max_tokens=30,
                messages=[{"role": "user", "content": task_prompt}],
            )
            content = completion.choices[0].message.content or ""
            return {"status": 200, "content": content.strip()}
        except APIStatusError as err:
            if err.status_code == 429 and attempt < max_retries:
                attempt += 1
                print(f"  ⚠️ Rate limit reached (HTTP 429). Retrying in {delay_s:.1f}s (attempt {attempt}/{max_retries})...")
                time.sleep(delay_s)
                delay_s *= 2  # exponential backoff
            else:
                raise


def main() -> None:
    print("=== Resilient Application: Rate Limiting & Backoff ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="rate-limit-demo",
        policy={
            "name": "rate-limit-policy",
            "mode": "enforce",
            "budgetMode": "hard",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "requestRateLimitPerMinute": 3,
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    print("Sending requests through rate-limited policy...\n")

    tasks = [
        'Translate "Hello" to French.',
        'Translate "Thank you" to Spanish.',
        'Translate "Good morning" to German.',
        'Translate "Goodbye" to Italian.',
        'Translate "Welcome" to Portuguese.',
    ]

    for i, task in enumerate(tasks):
        print(f'[Task {i + 1}] Submitting: "{task}"')
        try:
            result = execute_with_retry(client, task)
            print(f'  ✓ Completed: "{result["content"]}"\n')
        except Exception as err:
            print(f"  ❌ Task failed permanently: {err}\n")

    print("Review rate limit events and policy audit in the Cloptima Console:")
    print(f"  - Audit Trail: {CONSOLE['audit']}")
    print(f"  - Rate Limit Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
