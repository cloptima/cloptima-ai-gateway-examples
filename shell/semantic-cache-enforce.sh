#!/usr/bin/env bash
# Completes what exact-semantic-cache.sh deliberately leaves at 'observe':
# semanticCacheMode: 'enforce' needs a per-(app, route, model-family) class
# approval (createLLMSemanticCacheClassApproval) on top of the policy flag,
# AND setting 'enforce' on the policy itself auto-queues a separate entry in
# the generic governance queue (LLMGatewayApproval, approvalType
# 'semantic_cache_enforce') that must be reviewed before enforcement actually
# activates - until then, effective behavior stays downgraded to 'suggest'.
# This script creates the class approval and shows the auto-queued entry
# pending; it does not review/approve it - that decision belongs to a second
# privileged identity in the console's Audit tab, not to the requester's own
# script. See ../docs/CACHE_AND_POLICY.md.
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

echo "Creating policy with exact cache (enforce) and semantic cache (enforce)..."
POLICY=$(create_policy "$(jq -n --arg name "semantic-cache-enforce-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    promptRetentionMode: "full", exactCacheEnabled: true, exactCacheMode: "enforce",
    semanticCacheEnabled: true, semanticCacheMode: "enforce"}')")
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
PENDING=$(list_llm_gateway_approvals "pending" 50)
AUTO_QUEUED=$(echo "$PENDING" | jq -c --arg policyId "$POLICY_ID" '.[] | select(.approvalType == "semantic_cache_enforce" and .targetId == $policyId)')
if [ -n "$AUTO_QUEUED" ]; then
  echo "  pending: $AUTO_QUEUED"
  echo "  This is the one step this script does NOT do: reviewing it requires a second privileged identity in the"
  echo "  console's Audit tab ($CONSOLE_AUDIT). Until reviewed, semantic-cache enforcement stays downgraded to"
  echo "  'suggest' - exact-cache enforcement above is unaffected, since it isn't gated by this queue."
else
  echo "  no matching pending entry found (it may already have been reviewed on a prior run of this example)."
fi

echo ""
echo "Repeating one exact prompt 5x for exact-cache evidence (enforced immediately, no approval needed)..."
EXACT_PROMPT="Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month."
for i in 1 2 3 4 5; do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "$EXACT_PROMPT" "exact-cache-$i" \
    "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev" "x-cloptima-feature: exact_cache_probe"
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
    "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev" "x-cloptima-feature: semantic_cache_probe"
done

echo ""
echo "Expected: exact-cache hits show up immediately. Semantic-cache hits stay at 'suggest' (logged but not"
echo "served from cache) until the auto-queued approval above is reviewed - re-run this example after approving it"
echo "in the console to see semantic-cache enforcement actually take effect."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows both the pending semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab ($CONSOLE_POLICIES) shows the policy's cache config."
