#!/usr/bin/env bash
# Knowledge-base Q&A under a caching policy. Exact cache (enforce, full retention - required to
# replay cached responses) serves a repeated prompt without a model call. Semantic cache runs in
# observe mode: paraphrased questions are evaluated for hits (enforce mode additionally needs a
# per-app, per-route, per-model-family approval - see semantic-cache-enforce.sh).
#
# There is no client-side cache toggle: caching is entirely policy-driven (see
# ../docs/CACHE_AND_POLICY.md). Cache writes are processed in the background, so a repeat sent
# immediately after a write can transiently miss.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./exact-semantic-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"

echo "=== Knowledge Base Q&A: Exact and Semantic Caching ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "knowledge-cache-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "knowledge-cache-policy", mode: "enforce", budgetMode: "hard",
  allowedProviders: ["vertex_ai"], allowedModels: [$model],
  promptRetentionMode: "full",
  exactCacheEnabled: true, exactCacheMode: "enforce", exactCacheTtlSeconds: 3600,
  semanticCacheEnabled: true, semanticCacheMode: "observe", semanticCacheSimilarityThreshold: 0.85}')"

# Application code: ask a question and report latency.
ask() {
  local prompt="$1" label="$2" feature="$3"
  read -r HTTP_CODE TIME_TOTAL < <(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code} %{time_total}\n' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-feature: $feature" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$prompt" '{model: $model, messages: [{role: "user", content: $prompt}]}')")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  [$label] ${TIME_TOTAL}s | tokens: $(jq -r '.usage.total_tokens' "$RESP_BODY_FILE") | cached: $(jq -r '.usage.prompt_tokens_details.cached_tokens // 0' "$RESP_BODY_FILE")"
  else
    echo "  [$label] failed (HTTP $HTTP_CODE)"; describe_block
  fi
}

EXACT_PROMPT="Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month."
echo "Repeating one exact prompt 5 times (the first call is a miss; repeats can be served from the exact cache)..."
for i in 1 2 3 4 5; do
  ask "$EXACT_PROMPT" "exact-$i" "exact_cache_probe"
done

echo ""
echo "Sending 3 semantically similar (not identical) prompts..."
SEMANTIC_PROMPTS=(
  "In one sentence, explain why a customer running more Kubernetes pods saw higher cloud costs this month."
  "Give a one-sentence explanation for increased cloud spend when a customer scales up their Kubernetes pod count."
  "Why did this customer's cloud bill go up after running additional Kubernetes pods this month? One sentence."
)
for i in "${!SEMANTIC_PROMPTS[@]}"; do
  ask "${SEMANTIC_PROMPTS[$i]}" "semantic-$((i + 1))" "semantic_cache_probe"
done

echo ""
echo "Cache hit/miss decisions show up in the console, not in this script's output. Compare latency across the repeats above,"
echo "then check the console for the authoritative trail:"
echo "  - Dashboard (realized cache savings): $CONSOLE_DASHBOARD"
echo "  - Explorer (per-request cached tokens): $CONSOLE_SPEND"
echo "  - Audit (hit/miss trail): $CONSOLE_AUDIT"
