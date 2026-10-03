"""Multi-Tenant Cost Governance & Budget Overflow Handling

Demonstrates how to attribute inference spend to teams and applications,
and how an application gracefully handles policy budget limits.

Pattern:
1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
2. Attribute requests using team and application tags.
3. Send requests within budget (served normally).
4. Catch budget limit exhaustion (HTTP 402/403/429), alert or fall back gracefully.

Run standalone:
  python -m examples.budget_limit
"""
from openai import APIStatusError

from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE
from lib.models import MODELS

DAILY_BUDGET_USD = 0.001
MAX_TOKENS_PER_CALL = 100


def main() -> None:
    print("=== FinOps: Multi-Tenant Cost Governance & Budget Caps ===\n")

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    # hard_strict reserves against estimated cost derived from max_tokens pre-flight.
    access = get_access(
        app="budget-demo",
        policy={
            "name": "budget-policy",
            "mode": "enforce",
            "budgetMode": "hard_strict",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "dailyBudgetUsd": DAILY_BUDGET_USD,
        },
    )

    # Application code: the official SDK, pointed at the gateway with a virtual key.
    client = openai_client(access["virtual_key"])

    print(f"Executing workload under a policy with a ${DAILY_BUDGET_USD} daily budget cap.\n")

    successful_calls = 0
    budget_tripped = False

    # Execute requests in a loop until the small demo budget limit is reached
    for i in range(1, 31):
        try:
            completion = client.chat.completions.create(
                model=MODELS["default"],
                max_tokens=MAX_TOKENS_PER_CALL,
                messages=[{"role": "user", "content": f"Task #{i}: Generate a short status update."}],
            )
            successful_calls += 1
            content = completion.choices[0].message.content or ""
            tokens = completion.usage.total_tokens if completion.usage else 0
            print(f'[Call {i}] Allowed - Tokens: {tokens} | Assistant: "{content.strip()[:40]}..."')
        except APIStatusError as err:
            if err.status_code in (402, 403, 429):
                budget_tripped = True
                body = err.body if isinstance(err.body, dict) else {}
                message = body.get("message", str(err))
                violations = body.get("violations", ["gateway_daily_budget_exceeded"])

                print(f"\n🛑 [Call {i}] Gateway Budget Limit Intercepted (HTTP {err.status_code})")
                print(f"  Message: {message}")
                print(f"  Violations: {', '.join(violations)}")

                print("\nApplication FinOps Action:")
                print("  Daily budget quota reached. Application gracefully halted further non-critical requests.")
                print("  Alert dispatched to FinOps monitoring channel.\n")
                break
            else:
                raise

    print("Summary:")
    print(f"  - Successful calls admitted: {successful_calls}")
    print(f"  - Budget limit enforced: {'Yes' if budget_tripped else 'Quota not exhausted yet'}\n")

    print("Review allocated spend and team attribution in the Cloptima Console:")
    print(f"  - Spend Explorer: {CONSOLE['spend']}")
    print(f"  - Budget Policies: {CONSOLE['policies']}")


if __name__ == "__main__":
    main()
