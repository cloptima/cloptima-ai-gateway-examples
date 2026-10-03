#!/usr/bin/env bash
# Autonomous agent under runaway protection. The gateway counts tool-call turns and retries from
# the tool-call transcript already present in each request body, so no client-side tracking or
# session identifiers are needed.
#
# - maxLoopIterations: completed tool-result turns in the conversation so far.
# - maxRetryCount: scoped per tool_call_id, so retrying one call and starting a different call
#   are counted independently.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./agentic-runaway.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
# Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
MAX_LOOP_ITERATIONS=3
MAX_RETRY_COUNT=2

CHECK_STATUS_TOOL='{
  "type": "function",
  "function": {
    "name": "check_status",
    "description": "Check whether a long-running job has finished.",
    "parameters": {
      "type": "object",
      "properties": {"job_id": {"type": "string"}},
      "required": ["job_id"]
    }
  }
}'

echo "=== Autonomous Agent: Runaway Loop Protection ==="
echo ""

# Governance setup: the policy this application runs under. Platform admins normally create it
# once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY points at a
# key whose policy already matches.
get_access "agent-loop-demo" "$(jq -n --arg model "$MODEL_DEFAULT" --argjson loop "$MAX_LOOP_ITERATIONS" --argjson retry "$MAX_RETRY_COUNT" '{
  name: "agent-loop-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model],
  maxLoopIterations: $loop, maxRetryCount: $retry}')"

# Application code: one chat-completions turn with a growing transcript.
agent_turn() {
  local messages="$1" tool_choice="${2:-auto}"
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d "$(jq -n --arg model "$MODEL_DEFAULT" --argjson messages "$messages" --argjson tool "$CHECK_STATUS_TOOL" --arg choice "$tool_choice" '
      {model: $model, messages: $messages, tools: [$tool]}
      + (if $choice == "force" then {tool_choice: {type: "function", function: {name: "check_status"}}} else {} end)')")
}

echo "--- Case 1: Runaway Tool Loop (maxLoopIterations=$MAX_LOOP_ITERATIONS) ---"
MESSAGES='[{"role": "user", "content": "Call check_status for job \"job-42\" and keep checking until it is done."}]'
for turn in $(seq 1 $((MAX_LOOP_ITERATIONS + 2))); do
  echo "[Turn $turn] Agent requesting tool invocation..."
  agent_turn "$MESSAGES" force
  if [ "$HTTP_CODE" != "200" ]; then
    echo ""
    echo "[Turn $turn] Gateway runaway protection tripped (HTTP $HTTP_CODE)"
    describe_block
    echo ""
    echo "Agent supervisor action: loop terminated. Yielding control to a human operator with the current transcript."
    break
  fi
  TOOL_CALL_ID=$(jq -r '.choices[0].message.tool_calls[0].id' "$RESP_BODY_FILE")
  TOOL_CALL_ARGS=$(jq -r '.choices[0].message.tool_calls[0].function.arguments' "$RESP_BODY_FILE")
  echo "  Tool requested: check_status($TOOL_CALL_ARGS)"
  MESSAGES=$(jq -c --arg id "$TOOL_CALL_ID" --arg args "$TOOL_CALL_ARGS" --arg progress "$((turn * 20))%" '. + [
    {"role": "assistant", "tool_calls": [{"id": $id, "type": "function", "function": {"name": "check_status", "arguments": $args}}]},
    {"role": "tool", "tool_call_id": $id, "content": ({status: "pending", progress: $progress} | tojson)}
  ]' <<<"$MESSAGES")
done

echo ""
echo "--- Case 2: Repeated Retry of a Single Tool Call (maxRetryCount=$MAX_RETRY_COUNT) ---"
retry_transcript() {
  local call_id="$1"
  jq -nc --arg id "$call_id" '[
    {"role": "user", "content": "Call check_status for job \"job-99\"."},
    {"role": "assistant", "tool_calls": [{"id": $id, "type": "function", "function": {"name": "check_status", "arguments": "{\"job_id\": \"job-99\"}"}}]},
    {"role": "tool", "tool_call_id": $id, "content": "still running, check again"}
  ]'
}
for attempt in $(seq 1 $((MAX_RETRY_COUNT + 2))); do
  echo "[Attempt $attempt] Submitting tool result for call-job-99..."
  agent_turn "$(retry_transcript call-job-99)"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  Allowed"
  else
    echo ""
    echo "[Attempt $attempt] Gateway retry protection tripped (HTTP $HTTP_CODE)"
    describe_block
    echo ""
    echo "Agent supervisor action: max retries reached for call-job-99. Halting retries and reporting the error to the caller."
    break
  fi
done

echo ""
echo "A different tool_call_id starts its own retry count:"
agent_turn "$(retry_transcript call-job-100)"
echo "  [call-job-100, first attempt] HTTP $HTTP_CODE"

echo ""
echo "Review agent session telemetry in the Cloptima Console:"
echo "  - Audit Trail: $CONSOLE_AUDIT"
echo "  - Loop & Retry Policies: $CONSOLE_POLICIES"
