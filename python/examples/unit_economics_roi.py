"""Measuring LLM Business Value & Unit Economics: Cost Center vs Profit Center

This example demonstrates how production applications attribute real business value
and financial return to LLM inference calls using Cloptima:

1. Customer Support Automation (Cost Center):
   Resolving a customer inquiry avoids manual tier-1 support costs ($3.50 baseline).
   Its value is tracked through calibrated Net ROI (avoided cost minus LLM spend).

2. E-Commerce Checkout Upsell (Profit Center):
   Recommending complementary products at checkout generates incremental revenue.
   Its value is tracked through Gross Margin (booked revenue minus LLM spend).

Applications pass business outcome headers directly on inference calls:
- x-cloptima-business-transaction-type
- x-cloptima-business-outcome-status
- x-cloptima-business-value-cents

Run standalone:
  python -m examples.unit_economics_roi
"""
from datetime import datetime, timezone, timedelta
import json
from typing import Any, Dict, List, Optional
import requests

from lib import config, gateway_admin
from lib.access import provision_app
from lib.attribution import attribution_headers
from lib.client import openai_client
from lib.config import BASE_URL, USER_AGENT
from lib.models import MODELS

COST_CENTER_TYPE = "support_ticket_resolved"
PROFIT_CENTER_TYPE = "checkout_upsell_accepted"


def seed_roi_calibration(suffix: str) -> None:
    now = datetime.now(timezone.utc)
    effective_end = now + timedelta(days=365)

    print(f'Configuring FinOps ROI calibration for "{COST_CENTER_TYPE}"...')
    gateway_admin.graphql(
        """mutation UpsertROI($input: UpsertROICalibrationInput!) {
          upsertROICalibration(input: $input) { id }
        }""",
        {
            "input": {
                "transactionType": COST_CENTER_TYPE,
                "valuePerSuccessCents": 800,  # $8.00 estimated business value
                "preLlmBaselineCostCents": 350,  # $3.50 manual support handling cost
                "owner": "cloptima-ai-gateway-examples",
                "effectiveStart": now.isoformat(),
                "effectiveEnd": effective_end.isoformat(),
            }
        },
    )


def submit_unit_metrics(
    unit_type: str,
    unit_count: int,
    success_count: int,
    window_start: str,
    window_end: str,
    team_id: str,
    app_id: str,
    transaction_type: str,
    revenue_usd: Optional[float] = None,
) -> int:
    metric: Dict[str, Any] = {
        "unit_type": unit_type,
        "unit_count": unit_count,
        "successful_unit_count": success_count,
        "window_start": window_start,
        "window_end": window_end,
        "team_id": team_id,
        "app_id": app_id,
        "environment": "production",
        "business_transaction_type": transaction_type,
    }
    if revenue_usd is not None:
        metric["revenue_usd"] = f"{revenue_usd:.2f}"

    response = requests.post(
        f"{BASE_URL}/v1/ai/integrations/unit-metrics",
        headers={
            "content-type": "application/json",
            "user-agent": USER_AGENT,
            "authorization": f"Bearer {config.AI_ADMIN_KEY}",
        },
        json={"metrics": [metric]},
        timeout=30,
    )
    return response.status_code


def fetch_unit_economics_report(unit_type: str) -> List[dict]:
    try:
        report = gateway_admin.graphql(
            """query UnitEconomics($unitType: String!, $groupBy: String!, $window: String) {
              llmUnitEconomics(unitType: $unitType, groupBy: $groupBy, window: $window) {
                rows { bucket unitCount costPerUnitUsd marginUsd netRoiUsd calibratedBusinessValueUsd missingMetadata }
              }
            }""",
            {"unitType": unit_type, "groupBy": "app_id", "window": "30d"},
        )
        return (report.get("llmUnitEconomics") or {}).get("rows") or []
    except Exception as err:
        print(f"  (Report aggregation pending: {err})")
        return []


def main() -> None:
    suffix = config.run_suffix()
    seed_roi_calibration(suffix)

    # Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
    # key, and binding once in the Console, Terraform, or CI.
    setup = provision_app(
        app="unit-economics-demo",
        policy={
            "name": "unit-economics-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
        },
    )
    app_id = setup["app_id"]
    client = openai_client(setup["virtual_key"])

    # --- Scenario 1: Support Automation (Cost Center) ---
    print("\n--- Scenario 1: Support Automation (Cost Center) ---")
    support_tickets = [
        {"id": f"{suffix}-sup-1", "query": "How do I update the billing email address for my organization?"},
        {"id": f"{suffix}-sup-2", "query": "My API requests are failing with HTTP 401 unauthorized. Where do I get a new token?"},
    ]

    support_start = datetime.now(timezone.utc).isoformat()
    support_successes = 0

    for i, ticket in enumerate(support_tickets):
        try:
            headers = attribution_headers(
                business_transaction_type=COST_CENTER_TYPE,
                business_transaction_id=ticket["id"],
                business_transaction_unit_count=1,
                business_outcome_status="resolved",
                business_outcome_success=True,
                business_value_cents=750,
            )
            response = client.chat.completions.create(
                model=MODELS["default"],
                messages=[
                    {"role": "system", "content": "You are an automated support resolution assistant. Answer concisely in one sentence."},
                    {"role": "user", "content": ticket["query"]},
                ],
                extra_headers=headers,
            )
            support_successes += 1
            content = response.choices[0].message.content or ""
            print(f"[Ticket {i + 1}] Resolved: {ticket['query']}")
            print(f"Answer: {content.strip()}")
        except Exception as err:
            print(f"Ticket {i + 1} failed: {err}")

    submit_unit_metrics(
        unit_type="support_answers",
        unit_count=len(support_tickets),
        success_count=support_successes,
        window_start=support_start,
        window_end=datetime.now(timezone.utc).isoformat(),
        team_id="Support Automation",
        app_id=app_id,
        transaction_type=COST_CENTER_TYPE,
    )
    print(f"Submitted support unit metrics batch ({support_successes}/{len(support_tickets)} resolved).")

    # --- Scenario 2: E-Commerce Upsell (Profit Center) ---
    print("\n--- Scenario 2: E-Commerce Upsell (Profit Center) ---")
    upsells = [
        {"item": "Wireless Headphones", "upsell": "Protective Carrying Case", "value_usd": 19.99},
        {"item": "Espresso Machine", "upsell": "Organic Coffee Beans (1kg)", "value_usd": 24.50},
    ]

    upsell_start = datetime.now(timezone.utc).isoformat()
    total_revenue_usd = 0.0
    upsell_successes = 0

    for i, item in enumerate(upsells):
        try:
            headers = attribution_headers(
                business_transaction_type=PROFIT_CENTER_TYPE,
                business_transaction_id=f"{suffix}-upsell-{i + 1}",
                business_transaction_unit_count=1,
                business_outcome_status="accepted",
                business_outcome_success=True,
                business_value_cents=int(item["value_usd"] * 100),
            )
            response = client.chat.completions.create(
                model=MODELS["default"],
                messages=[
                    {"role": "system", "content": "Generate a short 1-sentence checkout upsell recommendation."},
                    {"role": "user", "content": f"Customer bought: {item['item']}. Suggest: {item['upsell']}."},
                ],
                extra_headers=headers,
            )
            upsell_successes += 1
            total_revenue_usd += item["value_usd"]
            content = response.choices[0].message.content or ""
            print(f"[Upsell {i + 1}] Item: {item['item']} -> Suggested: {item['upsell']} (Value: ${item['value_usd']})")
            print(f"Pitch: {content.strip()}")
        except Exception as err:
            print(f"Upsell {i + 1} failed: {err}")

    submit_unit_metrics(
        unit_type="checkout_upsells",
        unit_count=len(upsells),
        success_count=upsell_successes,
        window_start=upsell_start,
        window_end=datetime.now(timezone.utc).isoformat(),
        team_id="Growth Engineering",
        app_id=app_id,
        transaction_type=PROFIT_CENTER_TYPE,
        revenue_usd=total_revenue_usd,
    )
    print(f"Submitted upsell unit metrics batch (${total_revenue_usd:.2f} booked revenue).")

    # --- Unit Economics & ROI Reporting ---
    print("\n--- Cloptima Unit Economics & ROI Reports ---")
    support_report = fetch_unit_economics_report("support_answers")
    if support_report:
        print("Support Automation (Cost Avoidance / Net ROI):", json.dumps(support_report, indent=2))
    else:
        print("Support Automation metrics recorded. View aggregated ROI cards in Cloptima Economics tab.")

    upsell_report = fetch_unit_economics_report("checkout_upsells")
    if upsell_report:
        print("Checkout Upsell (Direct Revenue / Gross Margin):", json.dumps(upsell_report, indent=2))
    else:
        print("Checkout Upsell metrics recorded. View gross margin cards in Cloptima Economics tab.")


if __name__ == "__main__":
    main()
