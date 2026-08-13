#!/usr/bin/env bash
# Adaptive routing (certification/candidate contract, deterministic
# routing decision, canary cohorts) configures a certified set of candidate
# models per cost/latency tier under policy.metadata.routing.adaptive, a
# JSON object passed as policy metadata the same way route/fallback/cache
# controls are.
#
# This scopes to 'observe' mode: the router evaluates and logs which
# candidate it would have picked for each call, without actually changing
# where traffic goes - actual per-call routing decisions aren't visible in
# this script's own output (see the console evidence line below). Moving to
# 'canary' or 'enforce' additionally requires an approved_eval_id and an
# approved_release_gate_id - i.e. a passed eval run
# (prompt-release-workflow.sh) plus a DECIDED release-gate approval - and
# deciding that approval is the same kind of human-review step this repo's
# examples don't script (see approval-workflow.sh), so canary/enforce aren't
# demonstrated here.
# Run standalone: ./adaptive-routing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
MODEL_CHEAP="vertex_ai/gemini-2.5-flash-lite"
MODEL_STRONG="vertex_ai/gemini-2.5-pro"
SUFFIX="$(run_suffix)"
APP_ID="adaptive-routing-$SUFFIX"

echo "Creating a policy with adaptive routing in observe mode across cheap/balanced/strong candidate tiers..."
POLICY=$(create_policy "$(jq -n \
  --arg name "adaptive-routing-$SUFFIX" \
  --arg cheap "$MODEL_CHEAP" --arg balanced "$MODEL_DEFAULT" --arg strong "$MODEL_STRONG" \
  --arg candidateSetVersion "v$SUFFIX" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast",
    allowedProviders: ["vertex_ai"], allowedModels: [$cheap, $balanced, $strong],
    metadata: {routing: {adaptive: {
      mode: "observe", route_risk_ceiling: "low", candidate_set_version: $candidateSetVersion,
      candidate_models: {cheap: [$cheap], balanced: [$balanced], strong: [$strong]}
    }}}}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-adaptive-routing-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')
create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted key $(echo "$KEY" | jq -r '.id'), bound. Sending a few calls at the 'balanced' tier model..."
echo ""

for i in 1 2 3; do
  call_chat "$ACCESS_TOKEN" "$MODEL_DEFAULT" "Routing probe $i. In one sentence, confirm this call went through." \
    "routing-probe-$i" "x-cloptima-team: Platform AI" "x-cloptima-app: $APP_ID" "x-cloptima-environment: dev"
done

echo ""
echo "Expected: all 3 calls are served exactly as requested (observe mode never changes actual routing) - the"
echo "router logs, per call, which candidate it would have picked under this certified tier set. That decision"
echo "log isn't in this script's own output; it's a console-side evidence trail."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - shows the logged routing-decision trail per call; Policies tab ($CONSOLE_POLICIES) shows the metadata.routing.adaptive config, including the candidate tiers above."
