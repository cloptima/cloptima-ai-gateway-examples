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
# should need to know or configure its URL. Only override it (unset by
# default) for internal testing against a non-production environment.
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
