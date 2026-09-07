"""Automated cleanup script for Cloptima AI gateway example resources.

WARNING: This script permanently deletes all AI gateway policies, policy
bindings, registered tool servers, and pending approvals, and revokes all
active virtual keys in the authenticated account.

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

CONTROL_PLANE_QUERY = """
query GetControlPlaneAndApprovals {
  llmGatewayControlPlane {
    bindings { id policyId teamId appId }
    policies { id name }
    keys { id name status }
    toolServers { id name }
  }
  llmGatewayApprovals(status: "pending", limit: 100) {
    id
    approvalType
    status
  }
}
"""

DELETE_BINDING_MUTATION = """
mutation DeleteBinding($id: ID!) {
  deleteLLMGatewayPolicyBinding(id: $id)
}
"""

DELETE_POLICY_MUTATION = """
mutation DeletePolicy($id: ID!) {
  deleteLLMGatewayPolicy(id: $id)
}
"""

DELETE_TOOL_SERVER_MUTATION = """
mutation DeleteToolServer($id: ID!) {
  deleteLLMGatewayToolServer(id: $id)
}
"""

REVOKE_KEY_MUTATION = """
mutation RevokeKey($id: ID!) {
  revokeLLMGatewayKey(id: $id)
}
"""

REJECT_APPROVAL_MUTATION = """
mutation RejectApproval($id: ID!, $input: LLMGatewayApprovalReviewInput!) {
  reviewLLMGatewayApproval(id: $id, input: $input) {
    id
    status
  }
}
"""


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
    print("  registered tool servers, and pending approvals, and revokes ALL active")
    print("  virtual keys in the account associated with the configured CLOPTIMA_AI_ADMIN_KEY.")
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

    print("Fetching existing gateway resources...")
    data = graphql(CONTROL_PLANE_QUERY, {})
    control_plane = data.get("llmGatewayControlPlane") or {}
    bindings = control_plane.get("bindings") or []
    policies = control_plane.get("policies") or []
    keys = control_plane.get("keys") or []
    tool_servers = control_plane.get("toolServers") or []
    approvals = data.get("llmGatewayApprovals") or []

    active_keys = [k for k in keys if k.get("status") != "revoked"]

    print("Found:")
    print(f"  - {len(bindings)} policy binding(s)")
    print(f"  - {len(policies)} policy/policies")
    print(f"  - {len(tool_servers)} registered tool server(s)")
    print(f"  - {len(active_keys)} active virtual key(s) ({len(keys)} total)")
    print(f"  - {len(approvals)} pending approval request(s)")
    print()

    if not bindings and not policies and not tool_servers and not active_keys and not approvals:
        print("Account is already clean. No resources to delete.")
        return

    # 1. Delete bindings first
    deleted_bindings = 0
    for binding in bindings:
        try:
            graphql(DELETE_BINDING_MUTATION, {"id": binding["id"]})
            deleted_bindings += 1
        except Exception as err:
            print(f"  Failed to delete binding {binding['id']}: {err}")
    print(f"✓ Deleted {deleted_bindings}/{len(bindings)} policy binding(s)")

    # 2. Delete policies
    deleted_policies = 0
    for policy in policies:
        try:
            graphql(DELETE_POLICY_MUTATION, {"id": policy["id"]})
            deleted_policies += 1
        except Exception as err:
            print(f"  Failed to delete policy {policy.get('name')} ({policy['id']}): {err}")
    print(f"✓ Deleted {deleted_policies}/{len(policies)} policy/policies")

    # 3. Delete tool servers
    deleted_servers = 0
    for server in tool_servers:
        try:
            graphql(DELETE_TOOL_SERVER_MUTATION, {"id": server["id"]})
            deleted_servers += 1
        except Exception as err:
            print(f"  Failed to delete tool server {server.get('name')} ({server['id']}): {err}")
    print(f"✓ Deleted {deleted_servers}/{len(tool_servers)} tool server(s)")

    # 4. Revoke active keys
    revoked_keys = 0
    for key in active_keys:
        try:
            graphql(REVOKE_KEY_MUTATION, {"id": key["id"]})
            revoked_keys += 1
        except Exception as err:
            print(f"  Failed to revoke virtual key {key.get('name') or key['id']}: {err}")
    print(f"✓ Revoked {revoked_keys}/{len(active_keys)} active virtual key(s)")

    # 5. Reject pending approvals
    rejected_approvals = 0
    for approval in approvals:
        try:
            graphql(
                REJECT_APPROVAL_MUTATION,
                {
                    "id": approval["id"],
                    "input": {"decision": "reject", "reason": "Automated cleanup"},
                },
            )
            rejected_approvals += 1
        except Exception as err:
            print(f"  Failed to reject approval {approval['id']}: {err}")
    print(f"✓ Rejected {rejected_approvals}/{len(approvals)} pending approval request(s)")

    print("\nCleanup completed successfully.")


if __name__ == "__main__":
    main()
