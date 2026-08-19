#!/usr/bin/env bash
# Creates a policy with a realistic per-minute request rate cap, fires calls
# fast enough to exceed it, and shows the 429 once the cap is hit.
# Rate limits are evaluated per calendar minute (e.g. 10:00:00-10:00:59 UTC), not rolling 60s.
# Run standalone: ./rate-limit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
# Illustrative, not a platform minimum - change this and re-run to see the
# cap move. Bounds: requestRateLimitPerMinute accepts 1-1,000,000.
REQUEST_RATE_LIMIT_PER_MINUTE=20
CALLS_TO_FIRE=25
SUFFIX="$(run_suffix)"
APP_ID="rate-limit-$SUFFIX"

# 1. Cloptima setup - the policy, key, and binding are the whole contract.
echo "Creating policy with requestRateLimitPerMinute=$REQUEST_RATE_LIMIT_PER_MINUTE..."
POLICY=$(create_policy "$(jq -n --arg name "rate-limit-$SUFFIX" --arg model "$MODEL_DEFAULT" --argjson rate "$REQUEST_RATE_LIMIT_PER_MINUTE" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], requestRateLimitPerMinute: $rate}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-rate-limit-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound."

# 2. Your application code.
start_of_calendar_minute "$CALLS_TO_FIRE"
echo "Firing $CALLS_TO_FIRE calls back-to-back..."
echo ""

ALLOWED_COUNT=0
for i in $(seq 1 "$CALLS_TO_FIRE"); do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "Rate limit probe $i. Reply with just \"ok\"." \
    "call-$i"
  if [ "$LAST_OUTCOME" = "allowed" ]; then
    ALLOWED_COUNT=$((ALLOWED_COUNT + 1))
  else
    break
  fi
done

# 3. What the gateway did. confirm_cap_stopped stops the script if the cap
# never fired, so a silent regression cannot print as a success.
confirm_cap_stopped "$ALLOWED_COUNT" "$REQUEST_RATE_LIMIT_PER_MINUTE" "requestRateLimitPerMinute=$REQUEST_RATE_LIMIT_PER_MINUTE"
confirm_blocked "requestRateLimitPerMinute=$REQUEST_RATE_LIMIT_PER_MINUTE" 429

echo ""
echo "$ALLOWED_COUNT calls served, then call-$((ALLOWED_COUNT + 1)) returned 429 once the ${REQUEST_RATE_LIMIT_PER_MINUTE}/minute cap was reached."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - filter by app \"$APP_ID\" for the 429 block record; Policies tab ($CONSOLE_POLICIES) shows the requestRateLimitPerMinute config that fired."
