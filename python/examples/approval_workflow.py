"""Enterprise Governance: Policy Change Approvals & Audited Overrides

Demonstrates how Cloptima policies protect production runtime configurations
via dual-custody approval workflows:
1. Standard user submits policy budget change -> Request enters pending governance queue.
2. Production traffic continues safely uninterrupted under existing baseline policy.
3. Pre-authorized identity (e.g. CI/CD or platform admin) can apply approved changes immediately.

Run standalone:
  python -m examples.approval_workflow
"""
from lib import gateway_admin
from lib.access import provision_app
from lib.client import openai_client
from lib.models import MODELS

CURRENT_DAILY_BUDGET_USD = 5
REQUESTED_DAILY_BUDGET_USD = 25


def main() -> None:
    print(f"Initializing application with baseline daily budget of ${CURRENT_DAILY_BUDGET_USD}...")
    setup = provision_app(
        app="governed-app-demo",
        policy={
            "name": "governance-approval-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "dailyBudgetUsd": CURRENT_DAILY_BUDGET_USD,
        },
    )
    policy = setup["policy"]
    app_id = setup["app_id"]
    client = openai_client(setup["virtual_key"])

    print("\nExecuting normal application query under existing policy...")
    try:
        baseline = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "Confirm this application is running normally."}],
            temperature=0.3,
        )
        content = baseline.choices[0].message.content or ""
        print("Application status: Active (200 OK)")
        print(f'Response: "{content.strip()}"')
    except Exception as err:
        print(f"Baseline query failed: {err}")

    print(f"\nSubmitting governance change request to raise daily budget to ${REQUESTED_DAILY_BUDGET_USD}...")
    approval = gateway_admin.create_llm_gateway_approval({
        "approvalType": "budget_limit_change",
        "targetId": policy["id"],
        "requestedChange": {"daily_budget_usd": REQUESTED_DAILY_BUDGET_USD},
        "affectedApps": [app_id],
        "affectedRoutes": ["/v1/ai/chat/completions"],
        "expectedCostImpactCents": (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100,
        "expectedRiskReduction": "none - planned capacity increase for Q4 peak load",
        "metadata": {"requestedBy": "AI Platform Engineering", "reason": "Capacity expansion"},
    })
    print(f"Change request submitted: ID {approval['id']} (Status: {approval['status']})")

    print("\nInspecting enterprise governance queue...")
    pending = gateway_admin.list_llm_gateway_approvals(status="pending", limit=50)
    pending_match = next((a for a in pending if a["id"] == approval["id"]), None)
    if pending_match:
        print(f"Approval queue entry: ID {pending_match['id']} is pending secondary review.")
        print("Production safety: Existing $5.00 limit remains active until administrator approval.")

    print("\nExecuting post-request traffic to demonstrate uninterrupted runtime:")
    try:
        post_request = client.chat.completions.create(
            model=MODELS["default"],
            messages=[{"role": "user", "content": "What is the primary benefit of change approval queues in enterprise software?"}],
            temperature=0.3,
        )
        content = post_request.choices[0].message.content or ""
        print(f'Response: "{content.strip()}"')
    except Exception as err:
        print(f"Post-request query failed: {err}")

    print("\nDemonstrating automated CI/CD approval with pre-authorized identity (applyImmediately: true)...")
    automated = gateway_admin.create_llm_gateway_approval({
        "approvalType": "budget_limit_change",
        "targetId": policy["id"],
        "requestedChange": {"daily_budget_usd": REQUESTED_DAILY_BUDGET_USD + 10},
        "affectedApps": [app_id],
        "affectedRoutes": ["/v1/ai/chat/completions"],
        "expectedCostImpactCents": (REQUESTED_DAILY_BUDGET_USD + 10 - CURRENT_DAILY_BUDGET_USD) * 100,
        "expectedRiskReduction": "pre-authorized CI/CD deployment",
        "metadata": {"requestedBy": "CI/CD Pipeline"},
        "applyImmediately": True,
    })
    print(f"Automated approval result: ID {automated['id']} (Status: {automated['status']})")
    print("Governance state: Applied immediately, policy daily budget updated live.")


if __name__ == "__main__":
    main()
