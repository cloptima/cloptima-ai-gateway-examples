"""Seeds one enterprise contract price sheet (illustrative negotiated rates,
the same kind of input a real customer's finance/procurement team would
configure - not a real contract), approves it, logs a commitment against it,
makes a few real calls at the overridden model, and verifies the contracted
rate actually applied by checking the finance dashboard's real
retail-vs-contracted numbers for this account.

Run standalone from python/:
    python -m examples.contract_pricing
"""

import time
from datetime import datetime, timedelta, timezone

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

# vertex_ai/gemini-2.5-flash retail: $0.30 in / $2.50 out per million tokens
# (Cloptima's default LLM pricing catalog). ~20% off both - a realistic
# volume discount for a mid-size enterprise agreement.
PROVIDER = "vertex_ai"
MODEL = MODEL_DEFAULT.split("/")[-1]
CONTRACT_INPUT_RATE = 0.24
CONTRACT_OUTPUT_RATE = 2.0


def main():
    suffix = config.run_suffix()
    app_id = f"contract-pricing-{suffix}"
    now = datetime.now(timezone.utc)
    # A duration, not now.replace(year=now.year + 1): replace() raises
    # ValueError when now falls on Feb 29 and the following year isn't a
    # leap year.
    effective_end = now + timedelta(days=365)

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
                "cachedInputRatePerMillion": CONTRACT_INPUT_RATE,
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

    print("Creating a policy + key and making a few real calls at the contracted rate...")
    policy = create_policy({
        "name": f"contract-pricing-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": [PROVIDER], "allowedModels": [MODEL_DEFAULT],
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
            client, MODEL_DEFAULT, prompt,
            {"x-cloptima-team": "Finance", "x-cloptima-app": app_id, "x-cloptima-environment": "prod"},
            f"contract-call-{i + 1}",
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
