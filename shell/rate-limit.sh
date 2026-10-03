#!/usr/bin/env bash
# Batch worker under a per-minute request cap. When the gateway returns HTTP 429 the worker
# waits and retries with exponential backoff instead of failing the job.
# Rate limits are evaluated per calendar minute (e.g. 10:00:00-10:00:59 UTC), not a rolling 60s.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./rate-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
# Illustrative, not a platform minimum. Bounds: requestRateLimitPerMinute accepts 1-1,000,000.
REQUEST_RATE_LIMIT_PER_MINUTE=20
TASKS_TO_PROCESS=25
MAX_RETRIES=3

echo "=== Resilient Batch Worker: Rate Limiting & Backoff ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "rate-limit-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson rate "$REQUEST_RATE_LIMIT_PER_MINUTE" '{
  name: "rate-limit-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model], requestRateLimitPerMinute: $rate}')"

# Application code: process each task, backing off and retrying on HTTP 429.
process_task() {
  local task="$1" attempt=0 delay=2
  while true; do
    HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -H "User-Agent: $USER_AGENT" \
      -d "$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$task" '{model: $model, max_tokens: 30, messages: [{role: "user", content: $prompt}]}')")
    if [ "$HTTP_CODE" = "429" ] && [ "$attempt" -lt "$MAX_RETRIES" ]; then
      attempt=$((attempt + 1))
      echo "  Rate limit reached (HTTP 429). Retrying in ${delay}s (attempt $attempt/$MAX_RETRIES)..."
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi
    return 0
  done
}

# Wait for a fresh calendar-minute window so the whole burst lands in one window.
start_of_calendar_minute "$TASKS_TO_PROCESS"
echo "Processing $TASKS_TO_PROCESS tasks back-to-back (cap: $REQUEST_RATE_LIMIT_PER_MINUTE per minute)..."
echo ""

DONE_COUNT=0
for i in $(seq 1 "$TASKS_TO_PROCESS"); do
  process_task "Task $i: reply with just \"ok\"."
  if [ "$HTTP_CODE" = "200" ]; then
    DONE_COUNT=$((DONE_COUNT + 1))
    echo "  [Task $i] completed"
  else
    echo "  [Task $i] failed permanently (HTTP $HTTP_CODE)"
    describe_block
  fi
done

echo ""
echo "$DONE_COUNT of $TASKS_TO_PROCESS tasks completed. Tasks past the per-minute cap received HTTP 429; retries succeed only after the minute window resets."
echo "Review rate limit events and policy audit in the Cloptima Console:"
echo "  - Audit Trail: $CONSOLE_AUDIT"
echo "  - Rate Limit Policies: $CONSOLE_POLICIES"
