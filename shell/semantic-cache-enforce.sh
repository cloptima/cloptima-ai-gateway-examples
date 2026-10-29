#!/usr/bin/env bash
# Completes what exact-semantic-cache.sh deliberately leaves at 'observe'. The
# semantic cache modes are off, observe, and enforce. With
# semantic_cache_review_required: true, enforce mode serves a semantic hit only
# for an approved (app_id, route, model_family) class
# (POST /v1/llm/semantic-cache/class-approvals). Without an approved class,
# would-be hits are recorded but not served.
# On plans with approval workflows, setting 'enforce' with review required also
# queues an entry in the generic governance queue (approval_type
# 'semantic_cache_enforce'). This script creates the policy with
# apply_immediately: true, so - since the ai:admin key already qualifies to
# review this itself - that entry is approved in the same call, with no
# separate review step.
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
# A class approval names the model as the gateway records it: the model id
# without its provider prefix (gemini-3.5-flash-lite).
MODEL_FAMILY="${MODEL_DEFAULT##*/}"

# Governance setup: a policy with exact cache and semantic cache both in enforce mode.
# apply_immediately: true lets a qualifying admin key approve the auto-queued governance entry in
# the same call. Platform admins normally create this once in the Console, Terraform, or CI.
echo "Creating policy with exact cache (enforce) and semantic cache (enforce), apply_immediately: true..."
provision_app "semantic-cache-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "semantic-cache-enforce-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model],
  exact_cache_enabled: true, exact_cache_mode: "enforce",
  semantic_cache_enabled: true, semantic_cache_mode: "enforce", semantic_cache_review_required: true,
  apply_immediately: true}')"
echo "Minted key and bound it to app $APP_ID."
echo ""

echo "Requesting the class approval semantic-cache enforcement needs for (app=$APP_ID, route=$ROUTE, model_family=$MODEL_FAMILY)..."
CLASS_APPROVAL=$(admin_api POST /v1/llm/semantic-cache/class-approvals "" \
  "$(jq -n --arg app_id "$APP_ID" --arg route "$ROUTE" --arg model_family "$MODEL_FAMILY" --arg notes "semantic-cache-enforce example" \
    '{app_id: $app_id, route: $route, model_family: $model_family, notes: $notes}')")
echo "  class approval granted: $(jq -c '{id, app_id, route, model_family, created_at}' <<<"$CLASS_APPROVAL")"

echo ""
echo "Checking the generic governance queue for the entry auto-queued by semantic_cache_mode: 'enforce'..."
APPLIED=$(list_approvals '{"status": "applied", "limit": 50}')
AUTO_APPLIED=$(jq -c --arg policy_id "$POLICY_ID" '.items[] | select(.approval_type == "semantic_cache_enforce" and .target_id == $policy_id)
  | {id, approval_type, status, target_id, requested_at, required_approver_role}' <<<"$APPLIED")
if [ -n "$AUTO_APPLIED" ]; then
  echo "  applied: $AUTO_APPLIED"
  echo "  apply_immediately: true above meant this entry was approved and applied right away, instead of sitting"
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
echo "Because apply_immediately: true approved the governance entry, semantic-cache enforcement is live from the start."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the applied semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab ($CONSOLE_POLICIES) shows the policy's cache config."
