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
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (creates the policy, key, and class approval).
# Run standalone: ./semantic-cache-enforce.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
ROUTE="/v1/ai/chat/completions"
# The class approval's modelFamily must be keyed on the full canonical model
# ID (e.g. 'vertex_ai/gemini-3.5-flash-lite'), not just its last path segment
# (e.g. 'gemini-3.5-flash-lite') - modelFamily requires the full canonical model ID.
MODEL_FAMILY="$MODEL_DEFAULT"

# Governance setup: a policy with exact cache and semantic cache both in enforce mode.
# applyImmediately: true lets a qualifying admin key approve the auto-queued governance entry in
# the same call. Platform admins normally create this once in the Console, Terraform, or CI.
echo "Creating policy with exact cache (enforce) and semantic cache (enforce), applyImmediately: true..."
provision_app "semantic-cache-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "semantic-cache-enforce-policy", mode: "enforce", budgetMode: "hard",
  allowedProviders: ["vertex_ai"], allowedModels: [$model],
  promptRetentionMode: "full", exactCacheEnabled: true, exactCacheMode: "enforce",
  semanticCacheEnabled: true, semanticCacheMode: "enforce", applyImmediately: true}')"
echo "Minted key and bound it to app $APP_ID."
echo ""

echo "Requesting the class approval semantic-cache enforcement needs for (app=$APP_ID, route=$ROUTE, modelFamily=$MODEL_FAMILY)..."
CLASS_APPROVAL=$(graphql \
  'mutation CreateClassApproval($input: LLMSemanticCacheClassApprovalInput!) {
    createLLMSemanticCacheClassApproval(input: $input) { id appId route modelFamily createdAt }
  }' \
  "$(jq -n --arg appId "$APP_ID" --arg route "$ROUTE" --arg modelFamily "$MODEL_FAMILY" --arg notes "semantic-cache-enforce example" \
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

# Application code: exact repeats and paraphrases are served from the cache.
ask() {
  local prompt="$1" label="$2" feature="$3"
  read -r HTTP_CODE TIME_TOTAL < <(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code} %{time_total}\n' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-feature: $feature" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$prompt" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  [$label] ${TIME_TOTAL}s | tokens: $(jq -r '.usage.total_tokens' "$RESP_BODY_FILE")"
  else
    echo "  [$label] failed (HTTP $HTTP_CODE)"; describe_block
  fi
}

echo ""
echo "Repeating one exact prompt 5x for exact-cache evidence (enforced immediately, no approval needed)..."
EXACT_PROMPT="Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month."
for i in 1 2 3 4 5; do
  ask "$EXACT_PROMPT" "exact-cache-$i" "exact_cache_probe"
done

echo ""
echo "Sending 3 semantically similar (not identical) prompts for semantic-cache evidence..."
SEMANTIC_PROMPTS=(
  "In one sentence, explain why a customer running more Kubernetes pods saw higher cloud costs this month."
  "Give a one-sentence explanation for increased cloud spend when a customer scales up their Kubernetes pod count."
  "Why did this customer's cloud bill go up after running additional Kubernetes pods this month? One sentence."
)
for i in "${!SEMANTIC_PROMPTS[@]}"; do
  ask "${SEMANTIC_PROMPTS[$i]}" "semantic-cache-$((i + 1))" "semantic_cache_probe"
done

echo ""
echo "Because applyImmediately: true approved the governance entry, semantic-cache enforcement is live from the start."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the applied semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab ($CONSOLE_POLICIES) shows the policy's cache config."
