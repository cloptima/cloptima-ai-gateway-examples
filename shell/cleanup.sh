#!/usr/bin/env bash
# Automated cleanup script for Cloptima AI gateway example resources.
#
# WARNING: This script permanently deletes every AI gateway policy, policy
# binding, guardrail profile, registered tool server, eval dataset, and ROI
# calibration in the authenticated account. It also archives prompt templates
# and price sheets, revokes all active virtual keys and provider credentials,
# and rejects all pending approvals.
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
echo "  guardrail profiles, tool servers, eval datasets, and ROI calibrations;"
echo "  archives ALL prompt templates and price sheets; revokes ALL virtual keys"
echo "  and provider credentials; and rejects ALL pending approvals in the account"
echo "  associated with the configured CLOPTIMA_AI_ADMIN_KEY."
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

INVENTORY_QUERY='query GetCleanupInventory {
  llmGatewayControlPlane {
    bindings { id }
    policies { id name }
    keys { id name status }
    credentials { id displayName status }
    toolServers { id name }
  }
  llmGuardrailProfiles { id name }
  llmGatewayApprovals(status: "pending", limit: 100) { id status }
  llmPromptTemplates(limit: 100) { id name }
  llmDatasets(limit: 100) { id name }
  llmContractPriceSheets { id name status }
  llmROICalibrations { id }
}'

run_items() {
  local label="$1" verb="$2" filter="$3" mutation="$4" total done item id variables
  total=$(jq "$filter | length" <<<"$DATA")
  done=0
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    id=$(jq -r '.id' <<<"$item")
    variables=$(jq -n --arg id "$id" '{id: $id}')
    if graphql "$mutation" "$variables" >/dev/null 2>&1; then
      done=$((done + 1))
    else
      BATCH_FAILURES=$((BATCH_FAILURES + 1))
      echo "  Failed on $label $id" >&2
    fi
  done < <(jq -c "$filter[]" <<<"$DATA")
  echo "✓ $verb $done/$total $label"
}

run_approvals() {
  local total done item id variables
  total=$(jq '(.llmGatewayApprovals // []) | length' <<<"$DATA")
  done=0
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    id=$(jq -r '.id' <<<"$item")
    variables=$(jq -n --arg id "$id" '{id: $id, input: {decision: "reject", reason: "Automated cleanup"}}')
    if graphql 'mutation($id: ID!, $input: LLMGatewayApprovalReviewInput!) { reviewLLMGatewayApproval(id: $id, input: $input) { id } }' "$variables" >/dev/null 2>&1; then
      done=$((done + 1))
    else
      BATCH_FAILURES=$((BATCH_FAILURES + 1))
      echo "  Failed on pending approval request(s) $id" >&2
    fi
  done < <(jq -c '(.llmGatewayApprovals // [])[]' <<<"$DATA")
  echo "✓ Rejected $done/$total pending approval request(s)"
}

CLEANED_ANY=false
PREVIOUS_FINGERPRINT=""
while true; do
  if [ "$CLEANED_ANY" = "true" ]; then
    echo "Checking for remaining gateway resources..."
  else
    echo "Fetching existing gateway resources..."
  fi
  DATA=$(graphql "$INVENTORY_QUERY" '{}')
  FINGERPRINT=$(jq -r '[
    ((.llmGatewayControlPlane.bindings // [])[] | "binding:" + .id),
    ((.llmGatewayControlPlane.policies // [])[] | "policy:" + .id),
    ((.llmGuardrailProfiles // [])[] | "guardrail:" + .id),
    ((.llmGatewayControlPlane.toolServers // [])[] | "tool-server:" + .id),
    ((.llmGatewayControlPlane.keys // [])[] | select(.status != "revoked") | "key:" + .id),
    ((.llmGatewayControlPlane.credentials // [])[] | select(.status != "revoked") | "credential:" + .id),
    ((.llmGatewayApprovals // [])[] | "approval:" + .id),
    ((.llmPromptTemplates // [])[] | "prompt:" + .id),
    ((.llmDatasets // [])[] | "dataset:" + .id),
    ((.llmContractPriceSheets // [])[] | select(.status != "archived") | "price-sheet:" + .id),
    ((.llmROICalibrations // [])[] | "roi:" + .id)
  ] | sort | join("|")' <<<"$DATA")

  if [ -z "$FINGERPRINT" ]; then
    if [ "$CLEANED_ANY" = "true" ]; then
      echo ""
      echo "Cleanup completed successfully."
    else
      echo "Account is already clean. No resources to delete."
    fi
    exit 0
  fi
  if [ "$FINGERPRINT" = "$PREVIOUS_FINGERPRINT" ]; then
    echo "Cleanup failed: cleanup made no progress; one or more resources remain" >&2
    exit 1
  fi
  PREVIOUS_FINGERPRINT="$FINGERPRINT"

  echo "Found:"
  echo "  - $(jq '(.llmGatewayControlPlane.bindings // []) | length' <<<"$DATA") policy binding(s)"
  echo "  - $(jq '(.llmGatewayControlPlane.policies // []) | length' <<<"$DATA") policy/policies"
  echo "  - $(jq '(.llmGuardrailProfiles // []) | length' <<<"$DATA") guardrail profile(s)"
  echo "  - $(jq '(.llmGatewayControlPlane.toolServers // []) | length' <<<"$DATA") tool server(s)"
  echo "  - $(jq '[.llmGatewayControlPlane.keys[] | select(.status != "revoked")] | length' <<<"$DATA") active virtual key(s)"
  echo "  - $(jq '[.llmGatewayControlPlane.credentials[] | select(.status != "revoked")] | length' <<<"$DATA") active provider credential(s)"
  echo "  - $(jq '(.llmGatewayApprovals // []) | length' <<<"$DATA") pending approval request(s)"
  echo "  - $(jq '(.llmPromptTemplates // []) | length' <<<"$DATA") prompt template(s)"
  echo "  - $(jq '(.llmDatasets // []) | length' <<<"$DATA") eval dataset(s)"
  echo "  - $(jq '[.llmContractPriceSheets[] | select(.status != "archived")] | length' <<<"$DATA") active price sheet(s)"
  echo "  - $(jq '(.llmROICalibrations // []) | length' <<<"$DATA") ROI calibration(s)"
  echo ""

  BATCH_FAILURES=0
  run_items "policy binding(s)" "Deleted" '(.llmGatewayControlPlane.bindings // [])' 'mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }'
  run_items "policy/policies" "Deleted" '(.llmGatewayControlPlane.policies // [])' 'mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }'
  run_items "guardrail profile(s)" "Deleted" '(.llmGuardrailProfiles // [])' 'mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }'
  run_items "tool server(s)" "Deleted" '(.llmGatewayControlPlane.toolServers // [])' 'mutation($id: ID!) { deleteLLMGatewayToolServer(id: $id) }'
  run_items "active virtual key(s)" "Revoked" '[.llmGatewayControlPlane.keys[] | select(.status != "revoked")]' 'mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }'
  run_items "active provider credential(s)" "Revoked" '[.llmGatewayControlPlane.credentials[] | select(.status != "revoked")]' 'mutation($id: ID!) { revokeLLMProviderCredential(id: $id) }'
  run_approvals
  run_items "prompt template(s)" "Archived" '(.llmPromptTemplates // [])' 'mutation($id: ID!) { archiveLLMPromptTemplate(id: $id) }'
  run_items "eval dataset(s)" "Deleted" '(.llmDatasets // [])' 'mutation($id: ID!) { deleteLLMDataset(id: $id) }'
  run_items "active price sheet(s)" "Archived" '[.llmContractPriceSheets[] | select(.status != "archived")]' 'mutation($id: ID!) { archivePriceSheet(id: $id) { id } }'
  run_items "ROI calibration(s)" "Deleted" '(.llmROICalibrations // [])' 'mutation($id: ID!) { deleteROICalibration(id: $id) }'

  if [ "$BATCH_FAILURES" -gt 0 ]; then
    echo "Cleanup failed: $BATCH_FAILURES resource(s) could not be removed" >&2
    exit 1
  fi
  CLEANED_ANY=true
done
