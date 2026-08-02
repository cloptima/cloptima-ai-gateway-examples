"""Seeds two unit-economics scenarios side by side - a cost center and a
profit center - so both ways of measuring an LLM agent's business value
show up as real numbers, not claims:

1. A support-automation agent (cost center): resolving a ticket avoids a
   pre-LLM support cost rather than booking revenue, so its value is
   tracked as calibratedBusinessValueUsd/netRoiUsd against an ROI
   calibration row (value per success, and what handling it manually used
   to cost).
2. A checkout-upsell agent (profit center): each accepted upsell books
   real revenue_usd, so its value shows up as a positive marginUsd
   (revenue - spend) instead.

Run standalone from python/:
    python -m examples.unit_economics_roi
"""

import json
from datetime import datetime, timedelta, timezone

import requests

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.attribution import attribution_headers
from lib.models import MODEL_DEFAULT

COST_CENTER_TRANSACTION_TYPE = "support_ticket_resolved"
PROFIT_CENTER_TRANSACTION_TYPE = "checkout_upsell_accepted"


def submit_unit_metrics(*, unit_type, unit_count, success_count, window_start, window_end, team_id, app_id, transaction_type, revenue_usd=None):
    metric = {
        "unit_type": unit_type,
        "unit_count": unit_count,
        "successful_unit_count": success_count,
        "window_start": window_start,
        "window_end": window_end,
        "team_id": team_id, "app_id": app_id, "environment": "prod",
        "business_transaction_type": transaction_type,
    }
    if revenue_usd is not None:
        metric["revenue_usd"] = f"{revenue_usd:.2f}"
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/integrations/unit-metrics",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {config.AI_ADMIN_KEY}",
        },
        json={"metrics": [metric]},
        timeout=30,
    )
    print(f"Unit-metrics status={response.status_code} body={response.text}")


def read_unit_economics(unit_type):
    try:
        report = graphql(
            """query UnitEconomics($unitType: String!, $groupBy: String!, $window: String) {
              llmUnitEconomics(unitType: $unitType, groupBy: $groupBy, window: $window) {
                rows { bucket unitCount costPerUnitUsd marginUsd netRoiUsd calibratedBusinessValueUsd missingMetadata }
              }
            }""",
            {"unitType": unit_type, "groupBy": "app_id", "window": "30d"},
        )
        print(json.dumps(report["llmUnitEconomics"]["rows"], indent=2))
    except RuntimeError as err:
        print(f"Report not available yet (ledger aggregation may lag ingest): {err}")


def main():
    suffix = config.run_suffix()

    # --- Cost center: support automation -------------------------------
    support_app_id = f"unit-economics-support-{suffix}"
    print(f'Seeding an ROI calibration row for "{COST_CENTER_TRANSACTION_TYPE}" (illustrative, not customer-validated)...')
    now = datetime.now(timezone.utc)
    effective_end = now + timedelta(days=365)
    graphql(
        "mutation UpsertROI($input: UpsertROICalibrationInput!) { upsertROICalibration(input: $input) { id } }",
        {
            "input": {
                "transactionType": COST_CENTER_TRANSACTION_TYPE,
                "valuePerSuccessCents": 800,
                "preLlmBaselineCostCents": 350,
                "owner": "cloptima-ai-gateway-examples",
                "effectiveStart": now.isoformat(),
                "effectiveEnd": effective_end.isoformat(),
            },
        },
    )
    print("ROI calibration seeded.")

    print("Creating a policy + key and making a few real support-automation calls...")
    support_policy = create_policy({
        "name": f"unit-economics-support-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
    })
    support_key = create_virtual_key({"name": f"vk-unit-economics-support-{suffix}", "teamId": "Support Automation", "appId": support_app_id, "environment": "prod"})
    create_binding({"policyId": support_policy["id"], "teamId": "Support Automation", "appId": support_app_id, "environment": "prod", "priority": 10, "acknowledgeOverlap": True})

    support_client = openai_style_client(support_key["accessToken"], config.BASE_URL)
    # The unit-metrics window is anchored to the calibration's own effective
    # start, since the report only counts calibrated business value for the
    # portion of the window the calibration was active for.
    support_window_start = now.isoformat()
    support_prompts = [
        "A customer says their invoice total looks wrong for this month. Draft a short reply asking for the invoice number.",
        "A customer cannot log in after resetting their password. Draft a short reply with the next step.",
        "A customer wants to know why their monthly bill increased. Draft a short reply.",
    ]
    support_success_count = 0
    for i, prompt in enumerate(support_prompts):
        result = call_openai_style(
            support_client, MODEL_DEFAULT, prompt,
            attribution_headers(
                team_id="Support Automation", app_id=support_app_id, environment="prod",
                business_transaction_type=COST_CENTER_TRANSACTION_TYPE,
                business_transaction_id=f"{suffix}-support-{i}",
                business_transaction_unit_count=1,
                business_outcome_status="resolved",
                business_value_cents=750,
            ),
            f"support-ticket-{i + 1}",
        )
        if result["outcome"] == "allowed":
            support_success_count += 1
        print(f"  [{result['outcome']}] support-ticket-{i + 1}")

    print("\nSubmitting a unit-metrics batch for the support-automation window...")
    submit_unit_metrics(
        unit_type="support_answers",
        unit_count=len(support_prompts),
        success_count=support_success_count,
        window_start=support_window_start,
        window_end=datetime.now(timezone.utc).isoformat(),
        team_id="Support Automation",
        app_id=support_app_id,
        transaction_type=COST_CENTER_TRANSACTION_TYPE,
    )

    # --- Profit center: checkout upsell agent ---------------------------
    upsell_app_id = f"unit-economics-upsell-{suffix}"
    print("\nCreating a policy + key and making a few real checkout-upsell calls...")
    upsell_policy = create_policy({
        "name": f"unit-economics-upsell-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
    })
    upsell_key = create_virtual_key({"name": f"vk-unit-economics-upsell-{suffix}", "teamId": "Checkout Upsell", "appId": upsell_app_id, "environment": "prod"})
    create_binding({"policyId": upsell_policy["id"], "teamId": "Checkout Upsell", "appId": upsell_app_id, "environment": "prod", "priority": 10, "acknowledgeOverlap": True})

    upsell_client = openai_style_client(upsell_key["accessToken"], config.BASE_URL)
    upsell_window_start = datetime.now(timezone.utc).isoformat()
    upsells = [
        {"prompt": "A customer just added running shoes to their cart. Write a one-sentence checkout upsell for moisture-wicking socks.", "accepted_value_usd": 12.99},
        {"prompt": "A customer just added a laptop to their cart. Write a one-sentence checkout upsell for a protective sleeve.", "accepted_value_usd": 24.99},
        {"prompt": "A customer just added a coffee maker to their cart. Write a one-sentence checkout upsell for a bag of specialty coffee beans.", "accepted_value_usd": 16.99},
    ]
    upsell_success_count = 0
    accepted_revenue_usd = 0.0
    for i, upsell in enumerate(upsells):
        result = call_openai_style(
            upsell_client, MODEL_DEFAULT, upsell["prompt"],
            attribution_headers(
                team_id="Checkout Upsell", app_id=upsell_app_id, environment="prod",
                business_transaction_type=PROFIT_CENTER_TRANSACTION_TYPE,
                business_transaction_id=f"{suffix}-upsell-{i}",
                business_transaction_unit_count=1,
                business_outcome_status="accepted",
                business_value_cents=round(upsell["accepted_value_usd"] * 100),
            ),
            f"checkout-upsell-{i + 1}",
        )
        if result["outcome"] == "allowed":
            upsell_success_count += 1
            accepted_revenue_usd += upsell["accepted_value_usd"]
        print(f"  [{result['outcome']}] checkout-upsell-{i + 1} (${upsell['accepted_value_usd']:.2f} if accepted)")

    print("\nSubmitting a unit-metrics batch for the checkout-upsell window, with the real revenue those accepted upsells booked...")
    submit_unit_metrics(
        unit_type="checkout_upsells",
        unit_count=len(upsells),
        success_count=upsell_success_count,
        window_start=upsell_window_start,
        window_end=datetime.now(timezone.utc).isoformat(),
        team_id="Checkout Upsell",
        app_id=upsell_app_id,
        transaction_type=PROFIT_CENTER_TRANSACTION_TYPE,
        revenue_usd=accepted_revenue_usd,
    )

    print("\nReading back the cost-center report (support automation - value shows up as calibrated ROI, not margin)...")
    read_unit_economics("support_answers")

    print("\nReading back the profit-center report (checkout upsell - value shows up as a positive margin from real revenue)...")
    read_unit_economics("checkout_upsells")

    print(f"\nEvidence: Economics tab ({config.CONSOLE['unit_economics']}) shows both apps side by side - cost-per-unit, margin, and net-ROI, grouped by app.")


if __name__ == "__main__":
    main()
