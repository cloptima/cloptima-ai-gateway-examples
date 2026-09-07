#!/usr/bin/env bash
# Automated cleanup script for Cloptima AI gateway example resources.
#
# WARNING: This script permanently deletes all AI gateway policies, policy
# bindings, registered tool servers, and pending approvals, and revokes all
# active virtual keys in the authenticated account.
#
# Intended for sandbox, testing, or demo environments to clean up resources
# before or after evaluating example scripts.
#
# Usage:
#   ./cleanup.sh
#   ./cleanup.sh --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

IS_FORCE=false
for arg in "$@"; do
  if [ "$arg" = "--force" ] || [ "$arg" = "-y" ]; then
    IS_FORCE=true
  fi
done
if [ "${CI:-}" = "true" ] || [ "${NONINTERACTIVE:-}" = "true" ]; then
  IS_FORCE=true
fi

echo "================================================================================"
echo "  WARNING: AI Gateway Account Resource Cleanup"
echo "================================================================================"
echo "  This script permanently removes ALL AI gateway policies, policy bindings,"
echo "  registered tool servers, and pending approvals, and revokes ALL active"
echo "  virtual keys in the account associated with the configured CLOPTIMA_AI_ADMIN_KEY."
echo ""
echo "  Target Gateway: $BASE_URL"
echo ""
echo "  Do NOT run this script in an account with production policies or live traffic."
echo "  Use --force or -y to bypass interactive confirmation in automated workflows."
echo "================================================================================"
echo ""

if [ -t 0 ] && [ "$IS_FORCE" = "false" ]; then
  read -r -p "Are you sure you want to clean up all gateway resources? (y/N): " confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Cleanup aborted."; exit 0 ;;
  esac
  echo ""
fi

echo "Fetching existing gateway resources..."
CONTROL_PLANE_QUERY='query GetControlPlaneAndApprovals {
  llmGatewayControlPlane {
    bindings { id }
    policies { id name }
    keys { id name status }
    toolServers { id name }
  }
  llmGatewayApprovals(status: "pending", limit: 100) {
    id
    status
  }
}'

DATA=$(graphql "$CONTROL_PLANE_QUERY" '{}')

NUM_BINDINGS=$(echo "$DATA" | jq '(.llmGatewayControlPlane.bindings // []) | length')
NUM_POLICIES=$(echo "$DATA" | jq '(.llmGatewayControlPlane.policies // []) | length')
NUM_TOOL_SERVERS=$(echo "$DATA" | jq '(.llmGatewayControlPlane.toolServers // []) | length')
NUM_TOTAL_KEYS=$(echo "$DATA" | jq '(.llmGatewayControlPlane.keys // []) | length')
ACTIVE_KEY_IDS=$(echo "$DATA" | jq -r '(.llmGatewayControlPlane.keys // []) | map(select(.status != "revoked")) | .[].id')
if [ -n "$ACTIVE_KEY_IDS" ]; then
  NUM_ACTIVE_KEYS=$(echo "$ACTIVE_KEY_IDS" | wc -l | tr -d ' ')
else
  NUM_ACTIVE_KEYS=0
fi
NUM_APPROVALS=$(echo "$DATA" | jq '(.llmGatewayApprovals // []) | length')

echo "Found:"
echo "  - $NUM_BINDINGS policy binding(s)"
echo "  - $NUM_POLICIES policy/policies"
echo "  - $NUM_TOOL_SERVERS registered tool server(s)"
echo "  - $NUM_ACTIVE_KEYS active virtual key(s) ($NUM_TOTAL_KEYS total)"
echo "  - $NUM_APPROVALS pending approval request(s)"
echo ""

if [ "$NUM_BINDINGS" -eq 0 ] && [ "$NUM_POLICIES" -eq 0 ] && [ "$NUM_TOOL_SERVERS" -eq 0 ] && [ "$NUM_ACTIVE_KEYS" -eq 0 ] && [ "$NUM_APPROVALS" -eq 0 ]; then
  echo "Account is already clean. No resources to delete."
  exit 0
fi

# 1. Delete bindings
DELETED_BINDINGS=0
for id in $(echo "$DATA" | jq -r '(.llmGatewayControlPlane.bindings // [])[].id'); do
  vars=$(jq -n --arg id "$id" '{id: $id}')
  if graphql 'mutation DeleteBinding($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }' "$vars" >/dev/null 2>&1; then
    DELETED_BINDINGS=$((DELETED_BINDINGS + 1))
  else
    echo "  Failed to delete binding $id" >&2
  fi
done
echo "✓ Deleted $DELETED_BINDINGS/$NUM_BINDINGS policy binding(s)"

# 2. Delete policies
DELETED_POLICIES=0
for id in $(echo "$DATA" | jq -r '(.llmGatewayControlPlane.policies // [])[].id'); do
  vars=$(jq -n --arg id "$id" '{id: $id}')
  if graphql 'mutation DeletePolicy($id: ID!) { deleteLLMGatewayPolicy(id: $id) }' "$vars" >/dev/null 2>&1; then
    DELETED_POLICIES=$((DELETED_POLICIES + 1))
  else
    echo "  Failed to delete policy $id" >&2
  fi
done
echo "✓ Deleted $DELETED_POLICIES/$NUM_POLICIES policy/policies"

# 3. Delete tool servers
DELETED_SERVERS=0
for id in $(echo "$DATA" | jq -r '(.llmGatewayControlPlane.toolServers // [])[].id'); do
  vars=$(jq -n --arg id "$id" '{id: $id}')
  if graphql 'mutation DeleteToolServer($id: ID!) { deleteLLMGatewayToolServer(id: $id) }' "$vars" >/dev/null 2>&1; then
    DELETED_SERVERS=$((DELETED_SERVERS + 1))
  else
    echo "  Failed to delete tool server $id" >&2
  fi
done
echo "✓ Deleted $DELETED_SERVERS/$NUM_TOOL_SERVERS tool server(s)"

# 4. Revoke active keys
REVOKED_KEYS=0
if [ -n "$ACTIVE_KEY_IDS" ]; then
  for id in $ACTIVE_KEY_IDS; do
    vars=$(jq -n --arg id "$id" '{id: $id}')
    if graphql 'mutation RevokeKey($id: ID!) { revokeLLMGatewayKey(id: $id) }' "$vars" >/dev/null 2>&1; then
      REVOKED_KEYS=$((REVOKED_KEYS + 1))
    else
      echo "  Failed to revoke key $id" >&2
    fi
  done
fi
echo "✓ Revoked $REVOKED_KEYS/$NUM_ACTIVE_KEYS active virtual key(s)"

# 5. Reject pending approvals
REJECTED_APPROVALS=0
for id in $(echo "$DATA" | jq -r '(.llmGatewayApprovals // [])[].id'); do
  vars=$(jq -n --arg id "$id" '{id: $id, input: {decision: "reject", reason: "Automated cleanup"}}')
  if graphql 'mutation RejectApproval($id: ID!, $input: LLMGatewayApprovalReviewInput!) { reviewLLMGatewayApproval(id: $id, input: $input) { id status } }' "$vars" >/dev/null 2>&1; then
    REJECTED_APPROVALS=$((REJECTED_APPROVALS + 1))
  else
    echo "  Failed to reject approval $id" >&2
  fi
done
echo "✓ Rejected $REJECTED_APPROVALS/$NUM_APPROVALS pending approval request(s)"

echo ""
echo "Cleanup completed successfully."
