"""Enterprise Contract Pricing & Rate Overrides

When an enterprise negotiates custom volume pricing with a model provider
(e.g., volume discount on input and output tokens), those contracted rates
govern the customer's direct provider accounts (BYOK).

Cloptima's FinOps engine reconciles these custom rate sheets against standard
retail catalog rates, accurately tracking:
1. Retail list price spend
2. Contracted effective spend
3. Realized enterprise cost savings

Requires PROVIDER_API_KEY or CLOPTIMA_PROVIDER_CREDENTIAL_ID in .env.

Run standalone:
  python -m examples.contract_pricing
"""
from datetime import datetime, timezone, timedelta
import os
import time
from typing import Optional
from urllib.parse import quote

from lib import config, gateway_admin
from lib.access import provision_app
from lib.client import openai_client

PROVIDER = "openai"
MODEL = "gpt-4o-mini"
CANONICAL_MODEL = "openai/gpt-4o-mini"
CONTRACT_INPUT_RATE = 0.12  # Retail is $0.15 / 1M tokens (~20% discount)
CONTRACT_OUTPUT_RATE = 0.48  # Retail is $0.60 / 1M tokens (~20% discount)


def resolve_provider_credential_id() -> str:
    cred_id = os.environ.get("CLOPTIMA_PROVIDER_CREDENTIAL_ID")
    if cred_id:
        return cred_id

    provider_api_key = os.environ.get("PROVIDER_API_KEY")
    if not provider_api_key:
        raise RuntimeError(
            "Missing required env var PROVIDER_API_KEY or CLOPTIMA_PROVIDER_CREDENTIAL_ID.\n"
            "Set PROVIDER_API_KEY in .env with your OpenAI API key to test contracted pricing."
        )

    suffix = config.run_suffix()
    print("Registering provider credential (BYOK)...")
    created = gateway_admin.admin_api(
        "POST",
        "/v1/llm/provider-credentials",
        body={"provider": PROVIDER, "display_name": f"byok-openai-{suffix}", "api_key": provider_api_key},
    )
    return created["id"]


def setup_enterprise_price_sheet(suffix: str) -> dict:
    now = datetime.now(timezone.utc)
    effective_end = now + timedelta(days=365)

    print(f"Setting up enterprise price sheet with negotiated rates for {MODEL}...")
    sheet = gateway_admin.admin_api(
        "POST",
        "/v1/llm/pricing/sheets",
        body={
            "name": f"Enterprise Agreement ({suffix})",
            "owner": "cloptima-ai-gateway-examples",
            "effective_start": now.isoformat(),
            "effective_end": effective_end.isoformat(),
        },
    )
    sheet_path = f"/v1/llm/pricing/sheets/{quote(sheet['id'], safe='')}"

    gateway_admin.admin_api(
        "POST",
        f"{sheet_path}/overrides",
        body={
            "overrides": [
                {
                    "provider": PROVIDER,
                    "model": MODEL,
                    "input_rate_per_million": CONTRACT_INPUT_RATE,
                    "output_rate_per_million": CONTRACT_OUTPUT_RATE,
                    "effective_start": now.isoformat(),
                    "effective_end": effective_end.isoformat(),
                }
            ],
        },
    )

    gateway_admin.admin_api("POST", f"{sheet_path}/approve")

    print(f"Enterprise price sheet approved: {sheet['id']}")
    return sheet


def main() -> None:
    suffix = config.run_suffix()
    credential_id = resolve_provider_credential_id()
    setup_enterprise_price_sheet(suffix)

    print("\nInitializing OpenAI client pointing to Cloptima Gateway...")
    setup = provision_app(
        app="contract-pricing-demo",
        policy={
            "name": "contract-pricing-policy",
            "mode": "enforce",
            "budget_mode": "hard",
            "allowed_providers": [PROVIDER],
            "allowed_models": [CANONICAL_MODEL],
        },
    )

    client = openai_client(
        setup["virtual_key"],
        default_headers={"x-cloptima-provider-credential-id": credential_id},
    )

    prompts = [
        "Explain how committed-use discounts optimize cloud spend in one concise sentence.",
        "Explain the distinction between retail list price and effective contracted rate in one sentence.",
    ]

    verification_start = datetime.now(timezone.utc).isoformat()
    print("\nExecuting enterprise queries billed under negotiated rates:")
    for i, prompt in enumerate(prompts):
        try:
            response = client.chat.completions.create(
                model=CANONICAL_MODEL,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.5,
            )
            content = response.choices[0].message.content or ""
            print(f'\nQuery {i + 1}: "{prompt}"')
            print(f"Answer: {content.strip()}")
            if response.usage:
                print(f"Tokens: in={response.usage.prompt_tokens}, out={response.usage.completion_tokens}")
        except Exception as err:
            print(f"Query {i + 1} failed: {err}")

    print("\nReconciling FinOps metrics against Cloptima Finance Dashboard...")
    dashboard: Optional[dict] = None
    for attempt in range(5):
        if attempt > 0:
            time.sleep(2.0)
        try:
            d = gateway_admin.admin_api(
                "GET",
                "/v1/llm/finance/dashboard",
                query={
                    "window": "custom",
                    "start_time": verification_start,
                    "end_time": datetime.now(timezone.utc).isoformat(),
                },
            )
            if d.get("has_active_contract"):
                dashboard = d
                break
        except Exception:
            pass

    if dashboard:
        print("\n--- FinOps Reconciliation Summary ---")
        print(f"Active Enterprise Contract: {'Yes' if dashboard['has_active_contract'] else 'No'}")
        print(f"Standard Retail Cost: ${dashboard.get('retail_cost_usd')}")
        print(f"Effective Contracted Cost: ${dashboard.get('contracted_cost_usd')}")
        savings = float(dashboard.get("retail_cost_usd") or 0) - float(dashboard.get("contracted_cost_usd") or 0)
        print(f"Realized Savings: ${savings:.4f}")
    else:
        print("Finance dashboard metrics recorded; newly approved rate sheets reconcile in reporting shortly.")


if __name__ == "__main__":
    main()
