"""Automated cleanup script for Cloptima AI gateway example resources.

WARNING: This script permanently deletes every AI gateway policy, policy
binding, guardrail profile, registered tool server, eval dataset, and ROI
calibration in the authenticated account. It also archives prompt templates
and price sheets, revokes all active virtual keys and provider credentials,
and rejects all pending approvals.

Intended for sandbox, testing, or demo environments to clean up resources
before or after evaluating example scripts.

Usage:
    python -m examples.cleanup
    python -m examples.cleanup --force
"""

import os
import sys

from lib import config
from lib.gateway_admin import graphql

INVENTORY_QUERY = """
query GetCleanupInventory {
  llmGatewayControlPlane {
    bindings { id policyId teamId appId }
    policies { id name }
    keys { id name status }
    credentials { id displayName status }
    toolServers { id name }
  }
  llmGuardrailProfiles { id name }
  llmGatewayApprovals(status: "pending", limit: 100) { id approvalType status }
  llmPromptTemplates(limit: 100) { id name }
  llmDatasets(limit: 100) { id name }
  llmContractPriceSheets { id name status }
  llmROICalibrations { id }
}
"""

def mutate(document: str, item: dict, variables=None):
    graphql(document, variables or {"id": item["id"]})


STEPS = [
    {
        "label": "policy binding(s)",
        "items": lambda data: data["llmGatewayControlPlane"]["bindings"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }", item),
    },
    {
        "label": "policy/policies",
        "items": lambda data: data["llmGatewayControlPlane"]["policies"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }", item),
    },
    {
        "label": "guardrail profile(s)",
        "items": lambda data: data["llmGuardrailProfiles"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }", item),
    },
    {
        "label": "tool server(s)",
        "items": lambda data: data["llmGatewayControlPlane"]["toolServers"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteLLMGatewayToolServer(id: $id) }", item),
    },
    {
        "label": "active virtual key(s)",
        "verb": "Revoked",
        "items": lambda data: [item for item in data["llmGatewayControlPlane"]["keys"] if item.get("status") != "revoked"],
        "run": lambda item: mutate("mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }", item),
    },
    {
        "label": "active provider credential(s)",
        "verb": "Revoked",
        "items": lambda data: [item for item in data["llmGatewayControlPlane"]["credentials"] if item.get("status") != "revoked"],
        "run": lambda item: mutate("mutation($id: ID!) { revokeLLMProviderCredential(id: $id) }", item),
    },
    {
        "label": "pending approval request(s)",
        "verb": "Rejected",
        "items": lambda data: data["llmGatewayApprovals"],
        "run": lambda item: mutate(
            """mutation($id: ID!, $input: LLMGatewayApprovalReviewInput!) {
              reviewLLMGatewayApproval(id: $id, input: $input) { id }
            }""",
            item,
            {"id": item["id"], "input": {"decision": "reject", "reason": "Automated cleanup"}},
        ),
    },
    {
        "label": "prompt template(s)",
        "verb": "Archived",
        "items": lambda data: data["llmPromptTemplates"],
        "run": lambda item: mutate("mutation($id: ID!) { archiveLLMPromptTemplate(id: $id) }", item),
    },
    {
        "label": "eval dataset(s)",
        "items": lambda data: data["llmDatasets"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteLLMDataset(id: $id) }", item),
    },
    {
        "label": "active price sheet(s)",
        "verb": "Archived",
        "items": lambda data: [item for item in data["llmContractPriceSheets"] if item.get("status") != "archived"],
        "run": lambda item: mutate("mutation($id: ID!) { archivePriceSheet(id: $id) { id } }", item),
    },
    {
        "label": "ROI calibration(s)",
        "items": lambda data: data["llmROICalibrations"],
        "run": lambda item: mutate("mutation($id: ID!) { deleteROICalibration(id: $id) }", item),
    },
]


def main():
    is_force = (
        "--force" in sys.argv
        or "-y" in sys.argv
        or os.environ.get("CI") == "true"
        or os.environ.get("NONINTERACTIVE") == "true"
    )

    print("=" * 80)
    print("  WARNING: AI Gateway Account Resource Cleanup")
    print("=" * 80)
    print("  This script permanently removes ALL AI gateway policies, policy bindings,")
    print("  guardrail profiles, tool servers, eval datasets, and ROI calibrations;")
    print("  archives ALL prompt templates and price sheets; revokes ALL virtual keys")
    print("  and provider credentials; and rejects ALL pending approvals in the account")
    print("  associated with the configured CLOPTIMA_AI_ADMIN_KEY.")
    print()
    print(f"  Target Gateway: {config.BASE_URL}")
    print()
    print("  Do NOT run this script in an account with production policies or live traffic.")
    print("  Use --force or -y to bypass interactive confirmation in automated workflows.")
    print("=" * 80 + "\n")

    if sys.stdin.isatty() and not is_force:
        try:
            answer = input("Are you sure you want to clean up all gateway resources? (y/N): ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nCleanup aborted.")
            sys.exit(0)
        if answer not in ("y", "yes"):
            print("Cleanup aborted.")
            sys.exit(0)
        print()

    cleaned_any = False
    previous_fingerprint = None
    while True:
        print("Checking for remaining gateway resources..." if cleaned_any else "Fetching existing gateway resources...")
        inventory = graphql(INVENTORY_QUERY, {})
        plan = [{**step, "found": step["items"](inventory)} for step in STEPS]
        remaining = sum(len(step["found"]) for step in plan)
        if remaining == 0:
            print("\nCleanup completed successfully." if cleaned_any else "Account is already clean. No resources to delete.")
            return

        fingerprint = "|".join(sorted(
            f"{step['label']}:{item['id']}"
            for step in plan
            for item in step["found"]
        ))
        if fingerprint == previous_fingerprint:
            raise RuntimeError("cleanup made no progress; one or more resources remain")
        previous_fingerprint = fingerprint

        print("Found:")
        for step in plan:
            print(f"  - {len(step['found'])} {step['label']}")
        print()

        failures = 0
        for step in plan:
            done = 0
            for item in step["found"]:
                try:
                    step["run"](item)
                    done += 1
                except Exception as err:
                    failures += 1
                    item_name = item.get("name") or item.get("displayName") or item["id"]
                    print(f"  Failed on {step['label']} {item_name}: {err}")
            print(f"✓ {step.get('verb', 'Deleted')} {done}/{len(step['found'])} {step['label']}")

        if failures:
            raise RuntimeError(f"{failures} resource(s) could not be removed")
        cleaned_any = True


if __name__ == "__main__":
    main()
