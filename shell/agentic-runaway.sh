#!/usr/bin/env bash
# Creates a policy with realistic agentic-loop limits and simulates an agent
# retrying/looping via escalating x-cloptima-loop-iteration/retry-index
# headers, showing which iterations succeed vs. get blocked.
# Run standalone: ./agentic-runaway.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
MAX_RETRY_COUNT=5
MAX_LOOP_ITERATIONS=5
ITERATIONS_TO_SIMULATE=8
SUFFIX="$(run_suffix)"
APP_ID="agentic-runaway-$SUFFIX"

echo "Creating policy with maxRetryCount=$MAX_RETRY_COUNT, maxLoopIterations=$MAX_LOOP_ITERATIONS..."
POLICY=$(create_policy "$(jq -n --arg name "agentic-runaway-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  --argjson retry "$MAX_RETRY_COUNT" --argjson loop "$MAX_LOOP_ITERATIONS" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], maxRetryCount: $retry, maxLoopIterations: $loop}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-agentic-runaway-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Simulating $ITERATIONS_TO_SIMULATE escalating loop iterations..."
echo ""

SESSION_ID="$(new_uuid)"
for i in $(seq 0 $((ITERATIONS_TO_SIMULATE - 1))); do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" 'Simulated agent loop step. Reply with just "ok".' \
    "loop-iteration-$i" \
    "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev" \
    "x-cloptima-agent-session-id: $SESSION_ID" "x-cloptima-loop-iteration: $i" "x-cloptima-retry-index: $i"
done

echo ""
echo "Expected: iterations 0-$MAX_LOOP_ITERATIONS allowed, iteration $((MAX_LOOP_ITERATIONS + 1)) onward blocked"
echo "(\"exceeds the active Cloptima agent limits\") - this is what catches a genuinely runaway agent loop."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by agent session \"$SESSION_ID\" for the blocked loop iterations."
