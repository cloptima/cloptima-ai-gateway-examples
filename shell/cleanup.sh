#!/usr/bin/env bash
# Automated cleanup script for Cloptima AI gateway example resources.
#
# WARNING: This script permanently deletes every AI gateway policy, policy
# binding, guardrail profile, registered tool server, and ROI calibration in
# the authenticated account. It also archives price sheets, revokes all active
# virtual keys and provider credentials, and rejects all pending approvals.
#
# Intended for sandbox, testing, or demo environments to clean up resources
# before or after evaluating example scripts.
#
# Usage:
#   ./cleanup.sh
#   ./cleanup.sh --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

LIST_ERROR_FILE="$(mktemp)"
trap 'rm -f "$RESP_BODY_FILE" "$LIST_ERROR_FILE"' EXIT

IS_FORCE=false
for arg in "$@"; do
  if [ "$arg" = "--force" ] || [ "$arg" = "-y" ]; then
    IS_FORCE=true
  fi
done
if [ "${CI:-}" = "true" ] || [ "${NONINTERACTIVE:-}" = "true" ]; then
  IS_FORCE=true
fi

echo "================================================================================"
echo "  WARNING: AI Gateway Account Resource Cleanup"
echo "================================================================================"
echo "  This script permanently removes ALL AI gateway policies, policy bindings,"
echo "  guardrail profiles, tool servers, and ROI calibrations; archives ALL price"
echo "  sheets; revokes ALL virtual keys and provider credentials; and rejects ALL"
echo "  pending approvals in the account associated with the configured"
echo "  CLOPTIMA_AI_ADMIN_KEY."
echo ""
echo "  Target Gateway: $BASE_URL"
echo ""
echo "  Do NOT run this script in an account with production policies or live traffic."
echo "  Use --force or -y to bypass interactive confirmation in automated workflows."
echo "================================================================================"
echo ""

if [ -t 0 ] && [ "$IS_FORCE" = "false" ]; then
  read -r -p "Are you sure you want to clean up all gateway resources? (y/N): " confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Cleanup aborted."; exit 0 ;;
  esac
  echo ""
fi

# list_all <path> [query_json] -> prints every item on every page as one JSON
# array, following next_cursor.
list_all() {
  local path="$1" query="${2:-}" cursor="" items="[]" page
  if [ -z "$query" ]; then
    query='{}'
  fi
  while true; do
    page=$(admin_api GET "$path" "$(jq -c --arg cursor "$cursor" \
      '. + {limit: 100, cursor: (if $cursor == "" then null else $cursor end)}' <<<"$query")") || exit 1
    items=$(printf '%s\n%s' "$items" "$page" | jq -cs '.[0] + .[1].items') || exit 1
    cursor=$(jq -r '.next_cursor // empty' <<<"$page") || exit 1
    if [ -z "$cursor" ]; then
      break
    fi
  done
  echo "$items"
}

# list_active_keys -> prints every active virtual key as one JSON array. The
# virtual-key list pages by offset.
list_active_keys() {
  local offset=0 items="[]" page
  while true; do
    page=$(admin_api GET /v1/llm/gateway-keys "$(jq -n --argjson offset "$offset" \
      '{status: "active", limit: 100, offset: $offset}')") || exit 1
    items=$(printf '%s\n%s' "$items" "$page" | jq -cs '.[0] + .[1].items') || exit 1
    if [ "$(jq -r '.has_more' <<<"$page")" != "true" ]; then
      break
    fi
    offset=$((offset + $(jq '.items | length' <<<"$page")))
  done
  echo "$items"
}

# list_price_sheets -> prints every price sheet that is not archived.
list_price_sheets() {
  list_all /v1/llm/pricing/sheets | jq -c '[.[] | select(.status != "archived")]'
}

# list_roi_calibrations -> prints every ROI calibration. This list is not paged.
list_roi_calibrations() {
  admin_api GET /v1/llm/roi/calibrations | jq -c '.items'
}

SKIPPED_KEYS=" "

# is_skipped <inventory_key> -> succeeds when the plan does not include that
# resource type.
is_skipped() {
  case "$SKIPPED_KEYS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# list_step <inventory_key> <label> <plan_gated: true|false> <list command...>
# Runs the list command and adds its items to INVENTORY under <inventory_key>.
# A plan-gated step whose list call answers HTTP 403 is not on this plan: it is
# skipped for the rest of the run. Any other list error fails the run.
list_step() {
  local key="$1" label="$2" plan_gated="$3" items
  shift 3
  if is_skipped "$key"; then
    return 0
  fi
  if items=$("$@" 2>"$LIST_ERROR_FILE"); then
    INVENTORY+="$(jq -c --arg key "$key" '{($key): .}' <<<"$items")"$'\n'
    FOUND+="  - $(jq 'length' <<<"$items") $label"$'\n'
  elif [ "$plan_gated" = "true" ] && grep -q 'failed (HTTP 403):' "$LIST_ERROR_FILE"; then
    echo "Skipped $label: not available on this plan."
    SKIPPED_KEYS+="$key "
  else
    cat "$LIST_ERROR_FILE" >&2
    exit 1
  fi
}

# fetch_inventory -> sets DATA to one JSON object that maps each listed resource
# type to its items, and FOUND to one summary line per listed type.
fetch_inventory() {
  INVENTORY=""
  FOUND=""
  list_step bindings "policy binding(s)" false list_all /v1/llm/policy-bindings
  list_step policies "policy/policies" false list_all /v1/llm/policies
  list_step guardrail_profiles "guardrail profile(s)" false list_all /v1/llm/guardrail-profiles
  list_step tool_servers "tool server(s)" false list_all /v1/llm/tool-servers
  list_step keys "active virtual key(s)" false list_active_keys
  list_step credentials "active provider credential(s)" false list_all /v1/llm/provider-credentials '{"status": "active"}'
  # llm_approval_workflows and llm_contract_pricing are plan features.
  list_step approvals "pending approval request(s)" true list_all /v1/llm/approvals '{"status": "pending"}'
  list_step price_sheets "active price sheet(s)" true list_price_sheets
  list_step roi_calibrations "ROI calibration(s)" false list_roi_calibrations
  DATA=$(jq -cs 'add // {}' <<<"$INVENTORY")
}

# run_items <label> <verb> <inventory_key> <method> <path_prefix> [path_suffix] [body_json]
# Calls <method> <path_prefix>/<id><path_suffix> for every item in the inventory list.
run_items() {
  local label="$1" verb="$2" key="$3" method="$4" prefix="$5" suffix="${6:-}" body="${7:-}"
  local total done item id name error
  if is_skipped "$key"; then
    return 0
  fi
  total=$(jq --arg key "$key" '.[$key] | length' <<<"$DATA")
  done=0
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    id=$(jq -r '.id' <<<"$item")
    name=$(jq -r '.name // .display_name // .id' <<<"$item")
    if error=$(admin_api "$method" "$prefix/$(urlencode "$id")$suffix" "" "$body" 2>&1 >/dev/null); then
      done=$((done + 1))
    else
      BATCH_FAILURES=$((BATCH_FAILURES + 1))
      echo "  Failed on $label $name: $error" >&2
    fi
  done < <(jq -c --arg key "$key" '.[$key][]' <<<"$DATA")
  echo "✓ $verb $done/$total $label"
}

CLEANED_ANY=false
PREVIOUS_FINGERPRINT=""
while true; do
  if [ "$CLEANED_ANY" = "true" ]; then
    echo "Checking for remaining gateway resources..."
  else
    echo "Fetching existing gateway resources..."
  fi
  fetch_inventory
  FINGERPRINT=$(jq -r '[to_entries[] | .key as $key | .value[] | "\($key):\(.id)"] | sort | join("|")' <<<"$DATA")

  if [ -z "$FINGERPRINT" ]; then
    if [ "$CLEANED_ANY" = "true" ]; then
      echo ""
      echo "Cleanup completed successfully."
    else
      echo "Account is already clean. No resources to delete."
    fi
    exit 0
  fi
  if [ "$FINGERPRINT" = "$PREVIOUS_FINGERPRINT" ]; then
    echo "Cleanup failed: cleanup made no progress; one or more resources remain" >&2
    exit 1
  fi
  PREVIOUS_FINGERPRINT="$FINGERPRINT"

  echo "Found:"
  printf '%s' "$FOUND"
  echo ""

  BATCH_FAILURES=0
  run_items "policy binding(s)" "Deleted" bindings DELETE /v1/llm/policy-bindings
  run_items "policy/policies" "Deleted" policies DELETE /v1/llm/policies
  run_items "guardrail profile(s)" "Deleted" guardrail_profiles DELETE /v1/llm/guardrail-profiles
  run_items "tool server(s)" "Deleted" tool_servers DELETE /v1/llm/tool-servers
  run_items "active virtual key(s)" "Revoked" keys DELETE /v1/llm/gateway-keys
  run_items "active provider credential(s)" "Revoked" credentials DELETE /v1/llm/provider-credentials
  run_items "pending approval request(s)" "Rejected" approvals POST /v1/llm/approvals /review \
    '{"decision": "reject", "reason": "Automated cleanup"}'
  run_items "active price sheet(s)" "Archived" price_sheets POST /v1/llm/pricing/sheets /archive
  run_items "ROI calibration(s)" "Deleted" roi_calibrations DELETE /v1/llm/roi/calibrations

  if [ "$BATCH_FAILURES" -gt 0 ]; then
    echo "Cleanup failed: $BATCH_FAILURES resource(s) could not be removed" >&2
    exit 1
  fi
  CLEANED_ANY=true
done
