#!/usr/bin/env bash
# Shared helpers sourced by every example script in this directory.
# Each example has a governance-setup part (get_access / provision_app: policy,
# virtual key, binding) and an application part written as plain curl calls.
# Source this from an example with:
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
CONSOLE_POLICIES="$CONSOLE_ROOT/policies"
CONSOLE_GUARDRAILS="$CONSOLE_ROOT/guardrails"
CONSOLE_CREDENTIALS="$CONSOLE_ROOT/credentials"
CONSOLE_AUDIT="$CONSOLE_ROOT/audit"
CONSOLE_SESSIONS="$CONSOLE_ROOT/sessions"

load_env() {
  local env_file="$SCRIPT_DIR/.env"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
  CLOPTIMA_AI_ADMIN_KEY="${CLOPTIMA_AI_ADMIN_KEY:-}"
  CLOPTIMA_VIRTUAL_KEY="${CLOPTIMA_VIRTUAL_KEY:-}"
  BASE_URL="${CLOPTIMA_GATEWAY_BASE_URL:-$GATEWAY_BASE_URL_DEFAULT}"
  BASE_URL="${BASE_URL%/}"
}

require_admin_key() {
  if [ -z "$CLOPTIMA_AI_ADMIN_KEY" ]; then
    echo "This example creates governance resources and needs CLOPTIMA_AI_ADMIN_KEY. Add it to .env (see .env.example)." >&2
    exit 1
  fi
}

# A short, unique-ish suffix so re-running an example doesn't collide with a
# policy/app name it created on a previous run (policy names are unique per
# customer).
run_suffix() {
  printf '%04x%02x' "$((RANDOM % 65536))" "$((RANDOM % 256))"
}

# urlencode <value> -> prints the value percent-encoded for a URL path segment
# or query value.
urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

# admin_api <method> <path> [query_json] [body_json]
# Calls the Cloptima REST API with CLOPTIMA_AI_ADMIN_KEY and prints the JSON
# response body (nothing for 204 No Content). query_json is an object of query
# parameters: null values are left out, and an array value repeats its key.
# A POST always carries a JSON body; an operation that takes none gets {}.
# On a non-2xx status it prints the status and the error code and message to
# stderr and exits 1.
admin_api() {
  local method="$1" path="$2" query_json="${3:-}" body="${4:-}"
  local url="$BASE_URL$path" query response http_code detail
  require_admin_key
  if [ -n "$query_json" ]; then
    query=$(jq -r '[to_entries[] | .key as $key | (.value | if type == "array" then .[] else . end)
      | select(. != null) | "\($key | @uri)=\(tostring | @uri)"] | join("&")' <<<"$query_json") || exit 1
    if [ -n "$query" ]; then
      url="$url?$query"
    fi
  fi
  if [ -z "$body" ] && [ "$method" = "POST" ]; then
    body='{}'
  fi
  if [ -n "$body" ]; then
    response=$(printf '%s' "$body" | curl -sS -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $CLOPTIMA_AI_ADMIN_KEY" -H "User-Agent: $USER_AGENT" \
      -H "Content-Type: application/json" --data-binary @-) || exit 1
  else
    response=$(curl -sS -w '\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer $CLOPTIMA_AI_ADMIN_KEY" -H "User-Agent: $USER_AGENT") || exit 1
  fi
  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    detail=$(jq -er '.error | select(type == "object") | "\(.code): \(.message)"' <<<"$response" 2>/dev/null) || detail="$response"
    echo "$method $path failed (HTTP $http_code): $detail" >&2
    exit 1
  fi
  if [ -n "$response" ]; then
    printf '%s\n' "$response"
  fi
}

# create_policy <policy_json> -> prints the created policy
create_policy() {
  admin_api POST /v1/llm/policies "" "$1"
}

# create_guardrail_profile <profile_json> -> prints the created profile,
# including published_version
create_guardrail_profile() {
  admin_api POST /v1/llm/guardrail-profiles "" "$1"
}

# create_virtual_key <key_json> -> prints the created key, including
# access_token (shown once) and token_prefix
create_virtual_key() {
  admin_api POST /v1/llm/gateway-keys "" "$1"
}

# create_binding <binding_json> -> prints the created binding
create_binding() {
  admin_api POST /v1/llm/policy-bindings "" "$1"
}

# Generic governance queue - any policy, budget, or tool-server change that
# needs sign-off before it takes effect goes through this same queue, not a
# scenario-specific approval queue.
#
# create_approval <approval_json> -> prints the created approval:
# {id, approval_type, status, required_approver_role, target_id, requested_at, ...}
create_approval() {
  admin_api POST /v1/llm/approvals "" "$1"
}

# list_approvals [query_json] -> prints {items, next_cursor}.
# Query: status, search, limit, cursor.
list_approvals() {
  admin_api GET /v1/llm/approvals "${1:-}"
}

# list_session_steps <query_json> -> prints {agent_session_id, items, next_cursor}:
# one item per request in the agent session, with request_id, provider, model,
# status, input_tokens, output_tokens, cost_usd, requested_tool_names,
# response_tool_names, and trace_sha256. Query: session_id (required), window,
# limit, cursor.
list_session_steps() {
  admin_api GET /v1/llm/sessions/steps "$1"
}

# list_session_records <query_json> -> prints {agent_session_id, items, next_cursor}:
# the session's retained trace records, each with its integrity verification.
list_session_records() {
  admin_api GET /v1/llm/sessions/records "$1"
}

RESP_BODY_FILE="$(mktemp)"
trap 'rm -f "$RESP_BODY_FILE"' EXIT

TEAM_ID="AI Engineering"
ENVIRONMENT="development"

# provision_app <app> <policy_json> [guardrail_profile_json]
# Governance setup: creates the policy (and optional guardrail profile), a
# virtual key, and the binding that attaches the policy to that key's
# team/app/environment. Platform teams normally do this once in the Console,
# Terraform, or CI. Each example passes its policy definition inline so the
# configuration being demonstrated is visible next to the application code.
# Requires CLOPTIMA_AI_ADMIN_KEY. Sets SUFFIX, APP_ID, ACCESS_TOKEN, POLICY_ID,
# and PROFILE_ID (empty when no profile).
provision_app() {
  local app="$1" policy_json="$2" profile_json="${3:-}"
  local profile policy key
  SUFFIX="$(run_suffix)"
  APP_ID="$app-$SUFFIX"
  PROFILE_ID=""
  if [ -n "$profile_json" ]; then
    profile=$(create_guardrail_profile "$(jq -c --arg suffix "$SUFFIX" '.name += "-" + $suffix' <<<"$profile_json")")
    PROFILE_ID=$(jq -r '.id' <<<"$profile")
    policy_json=$(jq -c --arg profile_id "$PROFILE_ID" '.guardrail_profile_id = $profile_id' <<<"$policy_json")
  fi
  policy=$(create_policy "$(jq -c --arg suffix "$SUFFIX" '.name += "-" + $suffix' <<<"$policy_json")")
  POLICY_ID=$(jq -r '.id' <<<"$policy")
  key=$(create_virtual_key "$(jq -n --arg name "vk-$APP_ID" --arg team "$TEAM_ID" --arg app_id "$APP_ID" --arg env "$ENVIRONMENT" \
    '{name: $name, team_id: $team, app_id: $app_id, environment: $env}')")
  ACCESS_TOKEN=$(jq -r '.access_token' <<<"$key")
  create_binding "$(jq -n --arg policy_id "$POLICY_ID" --arg team "$TEAM_ID" --arg app_id "$APP_ID" --arg env "$ENVIRONMENT" \
    '{policy_id: $policy_id, team_id: $team, app_id: $app_id, environment: $env, priority: 10, acknowledge_overlap: true}')" >/dev/null
}

# get_access <app> <policy_json> [guardrail_profile_json]
# Sets ACCESS_TOKEN, the virtual key the application code should use.
# - CLOPTIMA_VIRTUAL_KEY set: use it as-is. The key must already be bound to a
#   policy equivalent to the one in the example's governance setup.
# - Otherwise: run the governance setup with CLOPTIMA_AI_ADMIN_KEY.
get_access() {
  if [ -n "$CLOPTIMA_VIRTUAL_KEY" ]; then
    echo "Using CLOPTIMA_VIRTUAL_KEY. The key should be bound to a policy like the governance setup in this file."
    echo ""
    ACCESS_TOKEN="$CLOPTIMA_VIRTUAL_KEY"
    APP_ID=""
    return 0
  fi
  if [ -z "$CLOPTIMA_AI_ADMIN_KEY" ]; then
    echo "Set CLOPTIMA_VIRTUAL_KEY to use an existing key, or CLOPTIMA_AI_ADMIN_KEY to let this example create its own policy and key (see .env.example)." >&2
    exit 1
  fi
  provision_app "$@"
}

# describe_block
# Prints the message, reason, and violations the gateway returned for a blocked
# request. The gateway reports a block as
#   {"error": "<message>", "reason": "...", "violations": ["..."]}
# and the response body is left in $RESP_BODY_FILE by the calling curl.
describe_block() {
  echo "  Message: $(jq -r '.error // .message // "blocked"' "$RESP_BODY_FILE" 2>/dev/null || cat "$RESP_BODY_FILE")"
  echo "  Reason: $(jq -r '.reason // "n/a"' "$RESP_BODY_FILE" 2>/dev/null || echo "n/a")"
  echo "  Violations: $(jq -r '(.violations // []) | if length == 0 then "none" else join(", ") end' "$RESP_BODY_FILE" 2>/dev/null || echo "none")"
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
