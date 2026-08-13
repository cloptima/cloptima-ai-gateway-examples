"""Demonstrates the generic governance queue for a manually-requested change,
distinct from semantic_cache_enforce.py's auto-queued entry. Requests a
budget increase on an existing policy (approvalType 'budget_limit_change').
Both requesting and deciding a change need an admin-or-owner identity, so an
ai:admin key can do either. requestedChange uses the snake_case keys
daily_budget_usd / monthly_budget_usd, not dailyBudgetUsd. It then lists the
request pending alongside the approval-type registry itself. The actual
approve/reject decision is deliberately NOT scripted here for the first
request - reviewLLMGatewayApproval is a real, callable mutation, but this
example stops at "request it, show it's pending" and leaves the decision to
a second identity in the console's Audit tab, same as any real governance
workflow would require. A second request at the end passes
applyImmediately: true, which - since this key already qualifies to decide
this itself - skips that separate step and applies right away.
Run standalone from python/:
    python -m examples.approval_workflow
"""

import json

from lib import config
from lib.gateway_admin import (
    create_binding,
    create_llm_gateway_approval,
    create_policy,
    create_virtual_key,
    graphql,
    list_llm_gateway_approvals,
)
from lib.gateway_clients import openai_style_client
from lib.call_gateway import call_openai_style
from lib.models import MODEL_DEFAULT

CURRENT_DAILY_BUDGET_USD = 5
REQUESTED_DAILY_BUDGET_USD = 25


def main():
    suffix = config.run_suffix()
    app_id = f"approval-workflow-{suffix}"

    print(f"Creating a baseline policy with dailyBudgetUsd=${CURRENT_DAILY_BUDGET_USD}...")
    policy = create_policy({
        "name": f"approval-workflow-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
        "dailyBudgetUsd": CURRENT_DAILY_BUDGET_USD,
    })
    key = create_virtual_key({"name": f"vk-approval-workflow-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.\n")

    print("Making one call under the current (unchanged) policy, to show normal traffic is unaffected by a pending request...")
    client = openai_style_client(key["accessToken"], config.BASE_URL)
    baseline = call_openai_style(
        client, MODEL_DEFAULT,
        "In one sentence, confirm this call is running under the current, unmodified policy.",
        {"x-cloptima-team": "Platform AI", "x-cloptima-app": app_id, "x-cloptima-environment": "dev"},
        "baseline-probe",
    )
    print(f"  [{baseline['outcome']}] baseline-probe")

    print(f"\nRequesting approval to raise dailyBudgetUsd from ${CURRENT_DAILY_BUDGET_USD} to ${REQUESTED_DAILY_BUDGET_USD}...")
    approval = create_llm_gateway_approval({
        "approvalType": "budget_limit_change",
        "targetId": policy["id"],
        "requestedChange": {"daily_budget_usd": REQUESTED_DAILY_BUDGET_USD},
        "affectedApps": [app_id],
        "affectedRoutes": ["/v1/ai/chat/completions"],
        "expectedCostImpactCents": (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100,
        "expectedRiskReduction": "none - this is a budget increase, not a risk-reducing change",
        "metadata": {"requestedBy": "approval-workflow example", "runSuffix": suffix},
    })
    print(f"  requested: {json.dumps(approval)}")

    print("\nListing the approval-type registry and this request in the pending queue...")
    data = graphql(
        "query ApprovalTypes { llmApprovalTypes { type targetType requiredRole } }",
        {},
    )
    print(f"  registry: {json.dumps(data['llmApprovalTypes'])}")
    pending = list_llm_gateway_approvals(status="pending", limit=50)
    ours = next((a for a in pending if a["id"] == approval["id"]), None)
    print(f"  this request, pending: {json.dumps(ours)}")

    print(
        f"\nExpected: the request sits in 'pending' status and the policy's dailyBudgetUsd stays at "
        f"${CURRENT_DAILY_BUDGET_USD} until a second identity reviews and approves it via "
        "reviewLLMGatewayApproval - not something this script does on its own behalf."
    )

    requested_daily_budget_usd_2 = REQUESTED_DAILY_BUDGET_USD + 10
    print("\nRequesting the same kind of budget increase again, this time with applyImmediately: true...")
    immediate_approval = create_llm_gateway_approval({
        "approvalType": "budget_limit_change",
        "targetId": policy["id"],
        "requestedChange": {"daily_budget_usd": requested_daily_budget_usd_2},
        "affectedApps": [app_id],
        "affectedRoutes": ["/v1/ai/chat/completions"],
        "expectedCostImpactCents": (requested_daily_budget_usd_2 - CURRENT_DAILY_BUDGET_USD) * 100,
        "expectedRiskReduction": "none - this is a budget increase, not a risk-reducing change",
        "metadata": {"requestedBy": "approval-workflow example", "runSuffix": suffix},
        "applyImmediately": True,
    })
    print(f"  result: {json.dumps(immediate_approval)}")

    print(
        "\nExpected: status is 'applied', not 'pending' - since this key already qualifies to decide this itself, "
        "the request is approved and applied in this same call, with no separate review step."
    )
    print(f"Evidence: Audit tab ({config.CONSOLE['audit']}) - shows the first request still pending and this second one already applied; Policies tab ({config.CONSOLE['policies']}) shows the policy's budget reflecting the applied change.")


if __name__ == "__main__":
    main()
