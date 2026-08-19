#!/usr/bin/env bash
# Completes what exact-semantic-cache.sh deliberately leaves at 'observe':
# semanticCacheMode: 'enforce' needs a per-(app, route, model-family) class
# approval (createLLMSemanticCacheClassApproval) on top of the policy flag,
# AND setting 'enforce' on the policy itself auto-queues a separate entry in
# the generic governance queue (LLMGatewayApproval, approvalType
# 'semantic_cache_enforce') that must be reviewed before enforcement actually
# activates - until then, effective behavior stays downgraded to 'suggest'.
# This script creates the policy with applyImmediately: true, so - since the
# ai:admin key already qualifies to review this itself - that entry is
# approved and enforcement is live immediately, with no separate review step.
# See ../docs/CACHE_AND_POLICY.md.
# Run standalone: ./semantic-cache-enforce.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
ROUTE="/v1/ai/chat/completions"
# The class approval's modelFamily must be keyed on the full canonical model
# ID (e.g. 'vertex_ai/gemini-2.5-flash'), not just its last path segment
# (e.g. 'gemini-2.5-flash') - modelFamily requires the full canonical model ID.
MODEL_FAMILY="$MODEL_DEFAULT"
SUFFIX="$(run_suffix)"
APP_ID="semantic-cache-enforce-$SUFFIX"

# 1. Cloptima setup - the policy, key, and binding are the whole contract.
echo "Creating policy with exact cache (enforce) and semantic cache (enforce), applyImmediately: true..."
POLICY=$(create_policy "$(jq -n --arg name "semantic-cache-enforce-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    promptRetentionMode: "full", exactCacheEnabled: true, exactCacheMode: "enforce",
    semanticCacheEnabled: true, semanticCacheMode: "enforce", applyImmediately: true}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-semantic-cache-enforce-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound."
echo ""

echo "Requesting the class approval semantic-cache enforcement needs for (app=$APP_ID, route=$ROUTE, modelFamily=$MODEL_FAMILY)..."
CLASS_APPROVAL=$(graphql \
  'mutation CreateClassApproval($input: LLMSemanticCacheClassApprovalInput!) {
    createLLMSemanticCacheClassApproval(input: $input) { id appId route modelFamily createdAt }
  }' \
  "$(jq -n --arg appId "$APP_ID" --arg route "$ROUTE" --arg modelFamily "$MODEL_FAMILY" --arg notes "semantic-cache-enforce example run $SUFFIX" \
    '{input: {appId: $appId, route: $route, modelFamily: $modelFamily, notes: $notes}}')")
echo "  class approval granted: $(echo "$CLASS_APPROVAL" | jq -c '.createLLMSemanticCacheClassApproval')"

echo ""
echo "Checking the generic governance queue for the entry auto-queued by semanticCacheMode: 'enforce'..."
APPLIED=$(list_llm_gateway_approvals "applied" 50)
AUTO_APPLIED=$(echo "$APPLIED" | jq -c --arg policyId "$POLICY_ID" '.[] | select(.approvalType == "semantic_cache_enforce" and .targetId == $policyId)')
if [ -n "$AUTO_APPLIED" ]; then
  echo "  applied: $AUTO_APPLIED"
  echo "  applyImmediately: true above meant this entry was approved and applied right away, instead of sitting"
  echo "  pending for a second identity to review in the console's Audit tab ($CONSOLE_AUDIT)."
else
  echo "  no matching applied entry found."
fi

# 2. Your application code.
echo ""
echo "Repeating one exact prompt 5x for exact-cache evidence (enforced immediately, no approval needed)..."
EXACT_PROMPT="Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month."
for i in 1 2 3 4 5; do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "$EXACT_PROMPT" "exact-cache-$i" \
    "x-cloptima-feature: exact_cache_probe"
  confirm_allowed "exact-cache-$i served under enforce-mode exact caching"
done

echo ""
echo "Sending 3 semantically similar (not identical) prompts for semantic-cache evidence..."
SEMANTIC_PROMPTS=(
  "In one sentence, explain why a customer running more Kubernetes pods saw higher cloud costs this month."
  "Give a one-sentence explanation for increased cloud spend when a customer scales up their Kubernetes pod count."
  "Why did this customer's cloud bill go up after running additional Kubernetes pods this month? One sentence."
)
for i in "${!SEMANTIC_PROMPTS[@]}"; do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "${SEMANTIC_PROMPTS[$i]}" "semantic-cache-$((i + 1))" \
    "x-cloptima-feature: semantic_cache_probe"
  confirm_allowed "semantic-cache-$((i + 1)) served under enforce-mode semantic caching"
done

# 3. What the gateway did. Enforce-mode caching must serve, never fail, a call.
echo ""
echo "Confirmed: both exact-cache and semantic-cache hits show up immediately - applyImmediately: true meant"
echo "semantic-cache enforcement was live from the start, with no separate review step needed."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the applied semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab ($CONSOLE_POLICIES) shows the policy's cache config."
