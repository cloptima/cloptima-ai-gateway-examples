#!/usr/bin/env bash
# Creates a policy with exact cache enabled (enforce mode, full retention -
# required to actually replay cached responses) and semantic cache enabled
# (observe mode - enforce mode needs an additional per-app/content-class/
# model-family approval on top of the policy flag). Repeats one exact prompt
# for exact-cache evidence, then sends paraphrased variants for semantic-
# cache evidence. There is no client-side cache toggle - this is entirely
# policy-driven server-side; see ../docs/CACHE_AND_POLICY.md.
# Run standalone: ./exact-semantic-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"
APP_ID="cache-demo-$SUFFIX"

echo "Creating policy with exact cache (enforce, full retention) and semantic cache (observe)..."
POLICY=$(create_policy "$(jq -n --arg name "exact-semantic-cache-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    promptRetentionMode: "full", exactCacheEnabled: true, exactCacheMode: "enforce",
    semanticCacheEnabled: true, semanticCacheMode: "observe"}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-cache-demo-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound."
echo ""

echo "Repeating one exact prompt 5x for exact-cache evidence..."
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
echo "Cache hit/miss decisions show up in the console, not in this script's own output - compare latency and"
echo "usage across the repeats above, then check the console for the authoritative hit/miss trail."
echo "Evidence: Dashboard tab ($CONSOLE_DASHBOARD) shows realized cache savings; Explorer tab ($CONSOLE_SPEND) shows per-request cached-token counts for the repeats above; Audit tab ($CONSOLE_AUDIT) has the authoritative hit/miss trail."
