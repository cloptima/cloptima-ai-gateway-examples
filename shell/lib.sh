#!/usr/bin/env bash
# Shared helpers sourced by every self-contained example script in this
# directory. Each example creates its own policy, virtual key, and binding
# using the shared ai:admin key, then exercises it - nothing is
# pre-provisioned. Source this from an example with:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }

# The gateway is a fixed public endpoint - nobody running these examples
# should need to know or configure its URL. GATEWAY_BASE_URL_DEFAULT is
# overridden only if CLOPTIMA_GATEWAY_BASE_URL is set; unset by default.
GATEWAY_BASE_URL_DEFAULT="https://api.cloptima.ai"

# The gateway sits behind Cloudflare, which bot-manages requests with no or
# generic User-Agent strings (curl's default "curl/x.y" UA looks like
# anonymous scripted traffic). Every raw curl call in this repo carries this
# identifying UA so it never silently trips bot detection.
USER_AGENT="Cloptima-AI-Gateway-Examples/1.0"

# Console tab URLs each example points to as corroborating evidence.
# These are the canonical, public paths to view results in the console.
CONSOLE_ROOT="https://app.cloptima.ai/llm"
CONSOLE_DASHBOARD="https://app.cloptima.ai"
CONSOLE_SPEND="$CONSOLE_ROOT/spend"
CONSOLE_UNIT_ECONOMICS="$CONSOLE_ROOT/unit-economics"
CONSOLE_RECOMMENDATIONS="$CONSOLE_ROOT/recommendations"
CONSOLE_POLICIES="$CONSOLE_ROOT/policies"
CONSOLE_CREDENTIALS="$CONSOLE_ROOT/credentials"
CONSOLE_AUDIT="$CONSOLE_ROOT/audit"

load_env() {
  local env_file="$SCRIPT_DIR/.env"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
  : "${CLOPTIMA_AI_ADMIN_KEY:?Set CLOPTIMA_AI_ADMIN_KEY - copy .env.example to .env and fill it in}"
  BASE_URL="${CLOPTIMA_GATEWAY_BASE_URL:-$GATEWAY_BASE_URL_DEFAULT}"
  BASE_URL="${BASE_URL%/}"
}

# A short, unique-ish suffix so re-running an example doesn't collide with a
# policy/app name it created on a previous run (policy names are unique per
# customer).
run_suffix() {
  printf '%04x%02x' "$((RANDOM % 65536))" "$((RANDOM % 256))"
}

new_uuid() {
  uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())'
}

# graphql <query> <variables_json> -> prints .data on success, exits 1 on error
graphql() {
  local query="$1" variables="$2"
  local body response
  body=$(jq -n --arg query "$query" --argjson variables "$variables" '{query: $query, variables: $variables}')
  response=$(curl -sS -X POST "$BASE_URL/graphql" \
    -H "Authorization: Bearer $CLOPTIMA_AI_ADMIN_KEY" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT" -d "$body")
  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    echo "GraphQL error: $(echo "$response" | jq -c '.errors')" >&2
    exit 1
  fi
  echo "$response" | jq '.data'
}

# create_policy <policy_input_json> -> prints {id, name}
create_policy() {
  local input="$1" variables
  variables=$(jq -n --argjson input "$input" '{input: $input}')
  graphql 'mutation CreatePolicy($input: LLMGatewayPolicyInput!) { createLLMGatewayPolicy(input: $input) { id name } }' \
    "$variables" | jq -c '.createLLMGatewayPolicy'
}

# create_virtual_key <key_input_json> -> prints {id, accessToken, tokenPrefix, expiresAt}
create_virtual_key() {
  local input="$1" variables
  variables=$(jq -n --argjson input "$input" '{input: $input}')
  graphql 'mutation CreateKey($input: CreateLLMGatewayKeyInput!) { createLLMGatewayKey(input: $input) { id accessToken tokenPrefix expiresAt } }' \
    "$variables" | jq -c '.createLLMGatewayKey'
}

# create_binding <binding_input_json> -> prints {id}
create_binding() {
  local input="$1" variables
  variables=$(jq -n --argjson input "$input" '{input: $input}')
  graphql 'mutation CreateBinding($input: LLMGatewayPolicyBindingInput!) { createLLMGatewayPolicyBinding(input: $input) { id } }' \
    "$variables" | jq -c '.createLLMGatewayPolicyBinding'
}

# Generic governance queue - any policy/budget/route change that needs
# sign-off before it takes effect goes through this same queue, not a
# scenario-specific approval queue. Shared by approval-workflow.sh and
# semantic-cache-enforce.sh (the latter reads it to show the auto-queued
# entry a semanticCacheMode: 'enforce' policy creates).
#
# create_llm_gateway_approval <approval_input_json> -> prints
# {id, approvalType, status, requiredApproverRole, targetId, requestedAt}
create_llm_gateway_approval() {
  local input="$1" variables
  variables=$(jq -n --argjson input "$input" '{input: $input}')
  graphql 'mutation CreateApproval($input: LLMGatewayApprovalInput!) {
      createLLMGatewayApproval(input: $input) {
        id approvalType status requiredApproverRole targetId requestedAt
      }
    }' "$variables" | jq -c '.createLLMGatewayApproval'
}

# list_llm_gateway_approvals [status] [limit] -> prints a JSON array of
# {id, approvalType, status, targetId, requestedAt, requiredApproverRole}
# Both arguments are optional (status omitted/empty means "no filter", limit
# defaults to 50) so calling this interactively after sourcing lib.sh - not
# just from a script that always supplies both - doesn't hand jq an empty
# string where it needs valid JSON.
list_llm_gateway_approvals() {
  local status="${1:-}" limit="${2:-50}" variables
  variables=$(jq -n --arg status "$status" --argjson limit "$limit" \
    '{status: (if $status == "" then null else $status end), limit: $limit, offset: null}')
  graphql 'query ListApprovals($status: String, $limit: Int, $offset: Int) {
      llmGatewayApprovals(status: $status, limit: $limit, offset: $offset) {
        id approvalType status targetId requestedAt requiredApproverRole
      }
    }' "$variables" | jq -c '.llmGatewayApprovals'
}

RESP_BODY_FILE="$(mktemp)"
trap 'rm -f "$RESP_BODY_FILE"' EXIT

# outcome_for_status <http_code> -> allowed | blocked | error
outcome_for_status() {
  local code="$1"
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then echo "allowed"
  elif [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then echo "blocked"
  else echo "error"
  fi
}

# call_chat <virtual_key> <model> <prompt> <label> [header: value ...]
# OpenAI-style call: POST /v1/ai/chat/completions with Authorization: Bearer <key>.
# Sets LAST_HTTP_CODE and LAST_OUTCOME globals so callers can branch on the
# real status instead of guessing from the response body.
call_chat() {
  local key="$1" model="$2" prompt="$3" label="$4"; shift 4
  local -a curl_headers=(-H "Authorization: Bearer $key" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT")
  for kv in "$@"; do curl_headers+=(-H "$kv"); done
  local body
  body=$(jq -n --arg model "$model" --arg prompt "$prompt" '{model: $model, messages: [{role: "user", content: $prompt}]}')
  LAST_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/ai/chat/completions" "${curl_headers[@]}" -d "$body")
  LAST_OUTCOME=$(outcome_for_status "$LAST_HTTP_CODE")
  echo "  [$LAST_OUTCOME] $label (http $LAST_HTTP_CODE)"
}

# call_messages <virtual_key> <model> <prompt> <label> [header: value ...]
# Anthropic-style call: POST /v1/messages with x-api-key: <key>, accepted
# specifically for Anthropic-SDK compatibility. Sets LAST_HTTP_CODE/LAST_OUTCOME.
call_messages() {
  local key="$1" model="$2" prompt="$3" label="$4"; shift 4
  local -a curl_headers=(-H "x-api-key: $key" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" -H "User-Agent: $USER_AGENT")
  for kv in "$@"; do curl_headers+=(-H "$kv"); done
  local body
  body=$(jq -n --arg model "$model" --arg prompt "$prompt" '{model: $model, max_tokens: 300, messages: [{role: "user", content: $prompt}]}')
  LAST_HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL/v1/messages" "${curl_headers[@]}" -d "$body")
  LAST_OUTCOME=$(outcome_for_status "$LAST_HTTP_CODE")
  echo "  [$LAST_OUTCOME] $label (http $LAST_HTTP_CODE)"
}

# The policy, binding, and virtual key an example creates are the entire
# contract. These confirm the gateway honoured that contract and stop the
# script with a specific message when it did not, so a run where enforcement
# quietly stopped working can never print as a success.
#
# Nothing here asks the gateway to enforce anything. No header, flag, or
# counter is sent - the only input is the configuration registered above.

confirm_allowed() {
  local what="$1"
  if [ "$LAST_OUTCOME" != "allowed" ]; then
    echo "ERROR: $what: expected this call to be served, got outcome=$LAST_OUTCOME status=$LAST_HTTP_CODE body=$(cat "$RESP_BODY_FILE")" >&2
    exit 1
  fi
}

confirm_blocked() {
  local what="$1"
  local expected_status="${2:-}"
  local violation="${3:-}"
  if [ "$LAST_OUTCOME" != "blocked" ]; then
    echo "ERROR: $what: expected the gateway to block this call, got outcome=$LAST_OUTCOME status=$LAST_HTTP_CODE body=$(cat "$RESP_BODY_FILE")" >&2
    exit 1
  fi
  if [ -n "$expected_status" ] && [ "$LAST_HTTP_CODE" -ne "$expected_status" ]; then
    echo "ERROR: $what: expected HTTP $expected_status, got outcome=$LAST_OUTCOME status=$LAST_HTTP_CODE body=$(cat "$RESP_BODY_FILE")" >&2
    exit 1
  fi
  if [ -n "$violation" ]; then
    local body
    body="$(cat "$RESP_BODY_FILE" 2>/dev/null || true)"
    if ! echo "$body" | grep -qi "$violation"; then
      echo "ERROR: $what: expected the block to name \"$violation\", got outcome=$LAST_OUTCOME status=$LAST_HTTP_CODE body=$body" >&2
      exit 1
    fi
  fi
}

confirm_cap_stopped() {
  local allowed_count="$1"
  local expected_allowed="${2:-}"
  local cap_name="$3"
  if [ "$LAST_OUTCOME" != "blocked" ]; then
    echo "ERROR: cap did not hold: all calls succeeded; $cap_name was expected to stop the burst" >&2
    exit 1
  fi
  if [ -n "$expected_allowed" ] && [ "$allowed_count" -ne "$expected_allowed" ]; then
    echo "ERROR: $cap_name: expected $expected_allowed calls allowed before cap, got $allowed_count" >&2
    exit 1
  fi
}

confirm_equals() {
  local actual="$1"
  local expected="$2"
  local what="$3"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: $what: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

# Rate limits are evaluated per calendar minute, so a burst that straddles a
# minute boundary is split across two windows and can stay under the cap in
# both. Waiting for a fresh window keeps the demonstration deterministic
# instead of dependent on what time it happens to run.
start_of_calendar_minute() {
  local calls="${1:-5}"
  local sec
  sec=$(date -u +%S | sed 's/^0*//')
  sec="${sec:-0}"
  local seconds_left=$((60 - sec))
  if [ "$seconds_left" -ge "$((calls + 5))" ]; then
    return 0
  fi
  echo "Waiting ${seconds_left}s for the next calendar minute so the whole burst lands in one window..."
  sleep "$seconds_left"
}
