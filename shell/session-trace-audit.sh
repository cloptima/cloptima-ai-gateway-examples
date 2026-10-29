#!/usr/bin/env bash
# Configures tool I/O capture on an agentic policy, runs a multi-tool agentic
# workflow with session correlation, and reads back the cryptographic ledger
# audit trail and tool trace records.
#
# In enterprise agentic systems, agents are often given access to multiple tools:
# standard lookups (check_order_status), financial actions (issue_refund), and
# external data sinks (export_customer_data). Auditing tool invocations and their
# exact arguments is critical to detect unintended behavior, prompt injection,
# or rogue models transmitting customer data to unapproved external endpoints.
#
# Setting prompt_retention_mode: 'tool_io' enables capturing tool calls, arguments,
# and results verbatim, while keeping conversational user text and system
# prompts uncollected to protect user privacy.
#
# Each step is anchored with a SHA-256 integrity hash (trace_sha256) on the
# ledger at request time, creating a tamper-evident audit record.
#
#
# Auth: CLOPTIMA_AI_ADMIN_KEY (creates the policy and key, and reads the session ledger).
# Run standalone: ./session-trace-audit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env
require_admin_key

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
SUFFIX="$(run_suffix)"
AGENT_SESSION_ID="session-$SUFFIX"
ORDER_ID="ORD-$((RANDOM % 90000 + 10000))"
CUSTOMER_ID="CUST-$((RANDOM % 9000 + 1000))"
EXTERNAL_WEBHOOK_URL="https://partner-audit.example.com/ingest"

# 1. Read-only order query tool
CHECK_ORDER_TOOL='{
  "type": "function",
  "function": {
    "name": "check_order_status",
    "description": "Look up order fulfillment and delivery status by order ID.",
    "parameters": {
      "type": "object",
      "properties": {"order_id": {"type": "string", "description": "The unique order identifier (e.g. ORD-98241)."}},
      "required": ["order_id"]
    }
  }
}'

# 2. Financial transaction tool
ISSUE_REFUND_TOOL='{
  "type": "function",
  "function": {
    "name": "issue_refund",
    "description": "Authorize and issue a financial refund for an order.",
    "parameters": {
      "type": "object",
      "properties": {
        "order_id": {"type": "string", "description": "The order identifier."},
        "amount_usd": {"type": "number", "description": "Refund amount in USD."},
        "reason": {"type": "string", "description": "Reason for refund."}
      },
      "required": ["order_id", "amount_usd", "reason"]
    }
  }
}'

# 3. Sensitive external egress tool (capable of transmitting customer data to external endpoints)
EXPORT_CUSTOMER_DATA_TOOL='{
  "type": "function",
  "function": {
    "name": "export_customer_data",
    "description": "Export customer details, account records, and order history to an external data sink or webhook URL.",
    "parameters": {
      "type": "object",
      "properties": {
        "customer_id": {"type": "string", "description": "The customer identifier."},
        "destination_url": {"type": "string", "description": "External HTTP endpoint or webhook URL to receive exported data."},
        "fields": {
          "type": "array",
          "items": {"type": "string"},
          "description": "Customer record fields to include in export (e.g. email, shipping_address, payment_history)."
        }
      },
      "required": ["customer_id", "destination_url", "fields"]
    }
  }
}'

TOOLS_JSON=$(jq -n --argjson a "$CHECK_ORDER_TOOL" --argjson b "$ISSUE_REFUND_TOOL" --argjson c "$EXPORT_CUSTOMER_DATA_TOOL" '[$a, $b, $c]')

# Governance setup: a policy with tool_io retention, bound to a production app. Platform admins
# normally create it once in the Console, Terraform, or CI.
echo "Creating policy with prompt_retention_mode: 'tool_io'..."
TEAM_ID="Support AI"; ENVIRONMENT="production"
provision_app "support-agent-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "session-trace-policy", mode: "enforce", budget_mode: "hard",
  allowed_providers: ["vertex_ai"], allowed_models: [$model], prompt_retention_mode: "tool_io"}')"
echo "  policy $POLICY_ID, key minted, bound to app \"$APP_ID\"."
echo ""

# Application code: every turn of the agent session carries the same x-cloptima-agent-session-id
# header, which correlates the turns into one session. Each turn posts the growing transcript.
agent_turn() {
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-agent-session-id: $AGENT_SESSION_ID" \
    -d "$1")
  if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: agent turn failed (HTTP $HTTP_CODE)" >&2
    describe_block >&2
    exit 1
  fi
}

MESSAGES=$(jq -n --arg orderId "$ORDER_ID" --arg customerId "$CUSTOMER_ID" --arg url "$EXTERNAL_WEBHOOK_URL" \
  '[{role: "user", content: ("Check delivery status for order " + $orderId + " (customer " + $customerId + "). If delivered, export the customer delivery confirmation to partner audit sink " + $url + ".")}]')

echo "Turn 1: User asks for order verification and conditional export..."
BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson messages "$MESSAGES" --argjson tools "$TOOLS_JSON" \
  '{model: $model, messages: $messages, tools: $tools, tool_choice: {type: "function", function: {name: "check_order_status"}}}')
agent_turn "$BODY"
TURN_COUNT=1

TOOL_CALL1_ID=$(jq -r '.choices[0].message.tool_calls[0].id // empty' "$RESP_BODY_FILE")
if [ -z "$TOOL_CALL1_ID" ]; then
  echo "ERROR: Expected model to return a tool call in Turn 1" >&2
  exit 1
fi
TOOL_CALL1_NAME=$(jq -r '.choices[0].message.tool_calls[0].function.name' "$RESP_BODY_FILE")
TOOL_CALL1_ARGS=$(jq -r '.choices[0].message.tool_calls[0].function.arguments' "$RESP_BODY_FILE")
echo "  Model invoked: $TOOL_CALL1_NAME($TOOL_CALL1_ARGS)"

MESSAGES=$(echo "$MESSAGES" | jq --arg id "$TOOL_CALL1_ID" --arg name "$TOOL_CALL1_NAME" --arg args "$TOOL_CALL1_ARGS" \
  --arg orderId "$ORDER_ID" --arg customerId "$CUSTOMER_ID" \
  '. + [
    {role: "assistant", tool_calls: [{id: $id, type: "function", function: {name: $name, arguments: $args}}]},
    {role: "tool", tool_call_id: $id, content: ({order_id: $orderId, customer_id: $customerId, status: "delivered", carrier: "FedEx", delivered_at: "2026-09-14T18:32:00Z"} | tojson)}
  ]')

echo ""
echo "Turn 2: Feeding status (\"delivered\") to model; model decides next action..."
BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson messages "$MESSAGES" --argjson tools "$TOOLS_JSON" \
  '{model: $model, messages: $messages, tools: $tools}')
agent_turn "$BODY"
TURN_COUNT=$((TURN_COUNT + 1))

TOOL_CALL2_ID=$(jq -r '.choices[0].message.tool_calls[0].id // empty' "$RESP_BODY_FILE")
if [ -n "$TOOL_CALL2_ID" ]; then
  TOOL_CALL2_NAME=$(jq -r '.choices[0].message.tool_calls[0].function.name' "$RESP_BODY_FILE")
  TOOL_CALL2_ARGS=$(jq -r '.choices[0].message.tool_calls[0].function.arguments' "$RESP_BODY_FILE")
  echo "  Model invoked: $TOOL_CALL2_NAME($TOOL_CALL2_ARGS)"
  echo "  -> Destination URL and customer fields captured in tool audit trail."

  TRANSACTION_ID="TXN-$((RANDOM % 900000 + 100000))"
  MESSAGES=$(echo "$MESSAGES" | jq --arg id "$TOOL_CALL2_ID" --arg name "$TOOL_CALL2_NAME" --arg args "$TOOL_CALL2_ARGS" \
    --arg txn "$TRANSACTION_ID" \
    '. + [
      {role: "assistant", tool_calls: [{id: $id, type: "function", function: {name: $name, arguments: $args}}]},
      {role: "tool", tool_call_id: $id, content: ({status: "success", exported_records: 1, destination_acknowledged: true, transaction_id: $txn} | tojson)}
    ]')

  echo ""
  echo "Turn 3: Completing session after tool execution..."
  BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson messages "$MESSAGES" --argjson tools "$TOOLS_JSON" \
    '{model: $model, messages: $messages, tools: $tools}')
  agent_turn "$BODY"
  TURN_COUNT=$((TURN_COUNT + 1))
  echo "  Model response: \"$(jq -r '.choices[0].message.content // empty' "$RESP_BODY_FILE")\""
else
  echo "  Model response: \"$(jq -r '.choices[0].message.content // empty' "$RESP_BODY_FILE")\""
fi

# 3. What the gateway did: inspect the ledger timeline and trace records.
# Ledger entries land a short moment after the response returns, not
# instantly - poll briefly instead of assuming a fixed delay is always
# enough, so the trace hash is reliably present on first read.
echo ""
echo "Querying session steps from the ledger (GET /v1/llm/sessions/steps)..."
AGENT_SESSION='{}'
for attempt in 0 1 2 3 4 5; do
  if [ "$attempt" -gt 0 ]; then
    sleep 0.75
  fi
  # A failed read is retried, like an incomplete one.
  if STEPS_RESULT=$(list_session_steps "$(jq -n --arg session_id "$AGENT_SESSION_ID" '{session_id: $session_id}')" 2>/dev/null); then
    AGENT_SESSION="$STEPS_RESULT"
    TRACES_READY=$(echo "$AGENT_SESSION" | jq --argjson expected "$TURN_COUNT" \
      '(.items | length) >= $expected and ([.items[].trace_sha256] | all)')
    if [ "$TRACES_READY" = "true" ]; then
      break
    fi
  fi
done
STEP_COUNT=$(echo "$AGENT_SESSION" | jq '.items // [] | length')
echo "  Session ID: $(echo "$AGENT_SESSION" | jq -r --arg id "$AGENT_SESSION_ID" '.agent_session_id // $id') ($STEP_COUNT steps recorded)"

for ((i = 0; i < STEP_COUNT; i++)); do
  STEP=$(echo "$AGENT_SESSION" | jq -c ".items[$i]")
  echo ""
  echo "  Step $((i + 1)):"
  echo "    Request ID: $(echo "$STEP" | jq -r '.request_id')"
  echo "    Provider / Model: $(echo "$STEP" | jq -r '.provider') / $(echo "$STEP" | jq -r '.model')"
  echo "    Status: $(echo "$STEP" | jq -r '.status') ($(echo "$STEP" | jq -r '.input_tokens') in / $(echo "$STEP" | jq -r '.output_tokens') out, cost: \$$(echo "$STEP" | jq -r '.cost_usd'))"
  echo "    Requested tools: $(echo "$STEP" | jq -r '(.requested_tool_names // []) | join(", ") | if . == "" then "none" else . end')"
  echo "    Invoked tool: $(echo "$STEP" | jq -r '(.response_tool_names // []) | join(", ") | if . == "" then "none" else . end')"
  echo "    Cryptographic Trace Hash (trace_sha256): $(echo "$STEP" | jq -r '.trace_sha256 // "none"')"
done

echo ""
echo "Querying session trace records (GET /v1/llm/sessions/records)..."
RECORDS_RESULT=$(list_session_records "$(jq -n --arg session_id "$AGENT_SESSION_ID" '{session_id: $session_id}')")
RECORDS=$(echo "$RECORDS_RESULT" | jq -c '.items // []')
RECORD_COUNT=$(echo "$RECORDS" | jq 'length')
echo "  Trace records available: $RECORD_COUNT"
echo "$RECORDS" | jq -r '.[] | "    Request: \(.request_id) -> verification: \(.verification)"'

echo ""
echo "Evidence: Sessions tab ($CONSOLE_SESSIONS?session=$AGENT_SESSION_ID) - inspect multi-turn tool call pairings, input parameters, and cryptographic verification."
