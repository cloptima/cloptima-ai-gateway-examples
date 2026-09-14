"""Enterprise contract price sheets and negotiated rate overrides apply to
customer-owned provider accounts and credentials (bring-your-own-key / BYOK).
When an enterprise negotiates custom pricing with a model provider, those
contracted rates govern the customer's own provider keys. Cloptima's
managed-credits wallet provides platform-funded compute at standard catalog
rates, so negotiated price sheets apply strictly to BYOK credentials.

This example registers an illustrative BYOK provider credential, seeds an
enterprise contract price sheet with a negotiated rate override on
openai/gpt-4o-mini, approves it, logs a commitment, executes real calls
routed through that credential, and verifies the finance dashboard reflects
the contracted cost below retail.

Requires PROVIDER_API_KEY (your own OpenAI-compatible key) in .env.
Run standalone from python/:
    python -m examples.contract_pricing
"""

import os
import time
from datetime import datetime, timedelta, timezone

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style


def _required_provider_key() -> str:
    value = os.environ.get("PROVIDER_API_KEY")
    if not value:
        raise RuntimeError("Missing required env var PROVIDER_API_KEY - set your own provider API key in .env.")
    return value


# openai/gpt-4o-mini retail: $0.15 in / $0.60 out per million tokens
# (Cloptima's default LLM pricing catalog). ~20% off both - a realistic
# volume discount for a negotiated enterprise agreement. No cached-token rate
# is negotiated here - a real procurement conversation prices input and
# output tokens, not a platform caching mechanism, so this leaves the cache
# rate unset and lets it resolve proportionally from retail instead of
# guessing a number.
PROVIDER = "openai"
MODEL = "gpt-4o-mini"
CANONICAL_MODEL = "openai/gpt-4o-mini"
CONTRACT_INPUT_RATE = 0.12
CONTRACT_OUTPUT_RATE = 0.48


def main():
    provider_api_key = _required_provider_key()
    suffix = config.run_suffix()
    app_id = f"contract-pricing-{suffix}"
    now = datetime.now(timezone.utc)
    # A duration, not now.replace(year=now.year + 1): replace() raises
    # ValueError when now falls on Feb 29 and the following year isn't a
    # leap year.
    effective_end = now + timedelta(days=365)

    print("Registering a provider credential (BYOK)...")
    created_credential = graphql(
        """mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
          createLLMProviderCredential(input: $input) { id provider displayName }
        }""",
        {"input": {"provider": PROVIDER, "displayName": f"byok-openai-{suffix}", "apiKey": provider_api_key}},
    )
    credential_id = created_credential["createLLMProviderCredential"]["id"]
    print(f"  credential {credential_id} ({created_credential['createLLMProviderCredential']['displayName']})")

    print(f"Creating an illustrative enterprise price sheet (~20% off retail on {MODEL})...")
    price_sheet = graphql(
        """mutation CreatePriceSheet($input: CreatePriceSheetInput!) {
          createPriceSheet(input: $input) { id name status }
        }""",
        {
            "input": {
                "name": f"Enterprise volume agreement ({suffix})",
                "owner": "cloptima-ai-gateway-examples",
                "effectiveStart": now.isoformat(),
                "effectiveEnd": effective_end.isoformat(),
            },
        },
    )["createPriceSheet"]
    print(f"  price sheet {price_sheet['name']} -> {price_sheet['id']} (status={price_sheet['status']})")

    print("Adding the negotiated rate override...")
    graphql(
        """mutation AddRateOverrides($priceSheetId: ID!, $overrides: [RateOverrideInput!]!) {
          addRateOverrides(priceSheetId: $priceSheetId, overrides: $overrides) {
            id provider model inputRatePerMillion outputRatePerMillion
          }
        }""",
        {
            "priceSheetId": price_sheet["id"],
            "overrides": [{
                "provider": PROVIDER,
                "model": MODEL,
                "inputRatePerMillion": CONTRACT_INPUT_RATE,
                "outputRatePerMillion": CONTRACT_OUTPUT_RATE,
                "effectiveStart": now.isoformat(),
                "effectiveEnd": effective_end.isoformat(),
            }],
        },
    )

    print("Approving the price sheet so it applies to real cost calculations...")
    graphql(
        "mutation ApprovePriceSheet($id: ID!) { approvePriceSheet(id: $id) { id status approvedAt } }",
        {"id": price_sheet["id"]},
    )

    print("Logging a commitment against this agreement...")
    graphql(
        """mutation CreateCommitment($input: CreateCommitmentInput!) {
          createCommitmentEntry(input: $input) { id name amountCents }
        }""",
        {
            "input": {
                "name": f"Annual commitment ({suffix})",
                "type": "upfront",
                "amountCents": "200000",
                "currency": "USD",
                "effectiveStart": now.isoformat(),
                "effectiveEnd": effective_end.isoformat(),
            },
        },
    )

    print("Creating a policy + key and making real BYOK calls at the contracted rate...")
    policy = create_policy({
        "name": f"contract-pricing-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": [PROVIDER], "allowedModels": [CANONICAL_MODEL],
    })
    key = create_virtual_key({"name": f"vk-contract-pricing-{suffix}", "teamId": "Finance", "appId": app_id, "environment": "prod"})
    create_binding({"policyId": policy["id"], "teamId": "Finance", "appId": app_id, "environment": "prod", "priority": 10, "acknowledgeOverlap": True})

    client = openai_style_client(key["accessToken"], config.BASE_URL)
    prompts = [
        "In one sentence, summarize why enterprise LLM contracts beat retail pricing.",
        "In one sentence, explain what a committed-use discount is.",
        "In one sentence, explain why effective cost differs from retail cost.",
    ]
    verification_start = datetime.now(timezone.utc).isoformat()
    allowed_count = 0
    for i, prompt in enumerate(prompts):
        result = call_openai_style(
            client, CANONICAL_MODEL, prompt,
            f"contract-call-{i + 1}",
            headers={"x-cloptima-provider-credential-id": credential_id},
        )
        print(f"  [{result['outcome']}] contract-call-{i + 1}")
        if result["outcome"] == "allowed":
            allowed_count += 1

    if allowed_count != len(prompts):
        raise RuntimeError(
            f"Expected all {len(prompts)} calls to succeed, but only {allowed_count} did - "
            "can't verify contracted pricing without real usage to check."
        )

    print("\nVerifying the contracted rate actually applied (checking the finance dashboard for real retail-vs-contracted numbers)...")
    # Scoped to calls made by this run, not the whole account's history.
    dashboard = None
    for attempt in range(5):
        if attempt > 0:
            time.sleep(2)
        result = graphql(
            """query Dashboard($startTime: DateTime!, $endTime: DateTime!) {
              llmFinanceDashboard(window: "custom", startTime: $startTime, endTime: $endTime) { retailCostUsd contractedCostUsd hasActiveContract }
            }""",
            {"startTime": verification_start, "endTime": datetime.now(timezone.utc).isoformat()},
        )
        d = result["llmFinanceDashboard"]
        if d["hasActiveContract"] and float(d["contractedCostUsd"]) < float(d["retailCostUsd"]):
            dashboard = d
            break
    if dashboard is None:
        raise RuntimeError(
            "Finance dashboard does not show contracted cost below retail cost after retrying - "
            "contract pricing does not appear to have applied."
        )
    print(f"  Confirmed: Finance dashboard shows real contracted cost ${dashboard['contractedCostUsd']} below retail cost ${dashboard['retailCostUsd']} for this account.")
    print(f"\nEvidence: Dashboard tab ({config.CONSOLE['dashboard']}) - Blended Effective Cost card shows retail vs. contracted vs. effective cost; open Contract Pricing to see this price sheet and its rate override.")


if __name__ == "__main__":
    main()
