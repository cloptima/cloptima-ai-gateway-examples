#!/usr/bin/env bash
# Creates policies with realistic agentic-loop and retry limits and drives
# real tool-calling conversations against the gateway, showing which turns
# succeed vs. get blocked.
#
# Both limits are derived entirely from the tool-call transcript already
# present in each request body - the growing sequence of tool calls and
# results a normal tool-calling client already sends for the model to have
# any memory of what it already tried. No client-declared session, step, or
# retry identifiers are involved anywhere below.
#
# Loop depth counts completed tool-result turns in the conversation so far.
# Retry count is scoped per tool_call_id, so retrying one specific call and
# starting a new, different call are counted independently.
#
# Run standalone: ./agentic-runaway.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
MAX_LOOP_ITERATIONS=3
MAX_RETRY_COUNT=2
SUFFIX="$(run_suffix)"

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

LOOP_APP_ID="agentic-loop-$SUFFIX"
echo "Creating policy with maxLoopIterations=$MAX_LOOP_ITERATIONS..."
LOOP_POLICY=$(create_policy "$(jq -n --arg name "agentic-loop-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  --argjson loop "$MAX_LOOP_ITERATIONS" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], maxLoopIterations: $loop}')")
LOOP_POLICY_ID=$(echo "$LOOP_POLICY" | jq -r '.id')

LOOP_KEY=$(create_virtual_key "$(jq -n --arg name "vk-agentic-loop-$SUFFIX" --arg appId "$LOOP_APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
LOOP_ACCESS_TOKEN=$(echo "$LOOP_KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$LOOP_POLICY_ID" --arg appId "$LOOP_APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$LOOP_KEY" | jq -r '.id'), bound."
echo ""

LOOP_ITERATIONS_TO_SIMULATE=$((MAX_LOOP_ITERATIONS + 2))
echo "Driving a real tool-calling loop for $LOOP_ITERATIONS_TO_SIMULATE turns..."
echo ""

MESSAGES='[{"role": "user", "content": "Call check_status for job \"job-42\" and keep checking until it is done."}]'
for i in $(seq 0 $((LOOP_ITERATIONS_TO_SIMULATE - 1))); do
  BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson messages "$MESSAGES" --argjson tool "$CHECK_STATUS_TOOL" \
    '{model: $model, messages: $messages, tools: [$tool], tool_choice: {type: "function", function: {name: "check_status"}}}')
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $LOOP_ACCESS_TOKEN" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$BODY")
  OUTCOME=$(outcome_for_status "$HTTP_CODE")
  echo "  [$OUTCOME] turn $i (http $HTTP_CODE)"
  if [ "$HTTP_CODE" -ne 200 ]; then
    break
  fi
  TOOL_CALL_ID=$(jq -r '.choices[0].message.tool_calls[0].id' "$RESP_BODY_FILE")
  TOOL_CALL_NAME=$(jq -r '.choices[0].message.tool_calls[0].function.name' "$RESP_BODY_FILE")
  TOOL_CALL_ARGS=$(jq -r '.choices[0].message.tool_calls[0].function.arguments' "$RESP_BODY_FILE")
  MESSAGES=$(echo "$MESSAGES" | jq --arg id "$TOOL_CALL_ID" --arg name "$TOOL_CALL_NAME" --arg args "$TOOL_CALL_ARGS" \
    '. + [
      {"role": "assistant", "tool_calls": [{"id": $id, "type": "function", "function": {"name": $name, "arguments": $args}}]},
      {"role": "tool", "tool_call_id": $id, "content": "still running, check again"}
    ]')
done

echo ""
echo "Expected: turns 0-$MAX_LOOP_ITERATIONS allowed, turn $((MAX_LOOP_ITERATIONS + 1)) onward blocked"
echo "(\"exceeds the active Cloptima agent limits\") - counted from the tool-call turns already present in the"
echo "conversation, not any client-supplied count."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$LOOP_APP_ID\" for the blocked turn."
echo ""

RETRY_APP_ID="agentic-retry-$SUFFIX"
echo "Creating policy with maxRetryCount=$MAX_RETRY_COUNT..."
RETRY_POLICY=$(create_policy "$(jq -n --arg name "agentic-retry-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  --argjson retry "$MAX_RETRY_COUNT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], maxRetryCount: $retry}')")
RETRY_POLICY_ID=$(echo "$RETRY_POLICY" | jq -r '.id')

RETRY_KEY=$(create_virtual_key "$(jq -n --arg name "vk-agentic-retry-$SUFFIX" --arg appId "$RETRY_APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
RETRY_ACCESS_TOKEN=$(echo "$RETRY_KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$RETRY_POLICY_ID" --arg appId "$RETRY_APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$RETRY_KEY" | jq -r '.id'), bound."
echo ""

RETRY_ITERATIONS_TO_SIMULATE=$((MAX_RETRY_COUNT + 2))
echo "Resubmitting the same tool call $RETRY_ITERATIONS_TO_SIMULATE times..."
echo ""

for i in $(seq 0 $((RETRY_ITERATIONS_TO_SIMULATE - 1))); do
  BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson tool "$CHECK_STATUS_TOOL" \
    '{
      model: $model,
      messages: [
        {"role": "user", "content": "Call check_status for job \"job-99\"."},
        {"role": "assistant", "tool_calls": [{"id": "call-job-99", "type": "function", "function": {"name": "check_status", "arguments": "{\"job_id\": \"job-99\"}"}}]},
        {"role": "tool", "tool_call_id": "call-job-99", "content": "still running, check again"}
      ],
      tools: [$tool]
    }')
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $RETRY_ACCESS_TOKEN" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
    -d "$BODY")
  OUTCOME=$(outcome_for_status "$HTTP_CODE")
  echo "  [$OUTCOME] attempt $i (http $HTTP_CODE)"
done

echo ""
echo "Expected: attempts 0-$MAX_RETRY_COUNT allowed, attempt $((MAX_RETRY_COUNT + 1)) onward blocked - counted"
echo "per tool_call_id, so a different call id gets its own independent count."

OTHER_BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson tool "$CHECK_STATUS_TOOL" \
  '{
    model: $model,
    messages: [
      {"role": "user", "content": "Call check_status for job \"job-99\"."},
      {"role": "assistant", "tool_calls": [{"id": "call-job-100", "type": "function", "function": {"name": "check_status", "arguments": "{\"job_id\": \"job-99\"}"}}]},
      {"role": "tool", "tool_call_id": "call-job-100", "content": "still running, check again"}
    ],
    tools: [$tool]
  }')
OTHER_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" \
  -H "Authorization: Bearer $RETRY_ACCESS_TOKEN" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" \
  -d "$OTHER_BODY")
OTHER_OUTCOME=$(outcome_for_status "$OTHER_HTTP_CODE")
echo "  [$OTHER_OUTCOME] a different tool_call_id, first attempt (http $OTHER_HTTP_CODE)"
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$RETRY_APP_ID\" for the blocked attempt."
