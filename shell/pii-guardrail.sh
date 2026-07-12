#!/usr/bin/env bash
# Two-step scenario, deliberately not a hardcoded "here's some fake PII"
# string: a hardcoded test string invites the fair objection "of course your
# detector matches its own fixture." Instead:
#   1. Ask the model itself, through an unguarded key, to invent a short
#      fictional support ticket containing fake PII. Nobody wrote this text;
#      the model generates it live, moments before step 2.
#   2. Feed that freshly-generated text through a second key bound to a
#      PII/secret guardrail policy. The guardrail has to detect content it
#      has never seen before.
# Run standalone: ./pii-guardrail.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-2.5-flash"
SUFFIX="$(run_suffix)"
GENERATOR_APP_ID="pii-guardrail-generator-$SUFFIX"
GUARDED_APP_ID="pii-guardrail-$SUFFIX"

echo "Creating an unguarded policy (to generate the fixture) and a guardrail-enforced policy..."
GENERATOR_POLICY=$(create_policy "$(jq -n --arg name "pii-guardrail-generator-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model]}')")
GUARDED_POLICY=$(create_policy "$(jq -n --arg name "pii-guardrail-$SUFFIX" --arg model "$MODEL_DEFAULT" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model],
    guardrailDetectorsEnabled: ["pii", "secret"], guardrailOutputAction: "redact"}')")

GENERATOR_KEY=$(create_virtual_key "$(jq -n --arg name "vk-pii-generator-$SUFFIX" --arg appId "$GENERATOR_APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
GUARDED_KEY=$(create_virtual_key "$(jq -n --arg name "vk-pii-guardrail-$SUFFIX" --arg appId "$GUARDED_APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "dev"}')")
create_binding "$(jq -n --arg policyId "$(echo "$GENERATOR_POLICY" | jq -r '.id')" --arg appId "$GENERATOR_APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
create_binding "$(jq -n --arg policyId "$(echo "$GUARDED_POLICY" | jq -r '.id')" --arg appId "$GUARDED_APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "dev", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "Minted both keys, bound. Generating a fictional PII-bearing ticket live..."
echo ""

call_chat "$(echo "$GENERATOR_KEY" | jq -r '.accessToken')" "$MODEL_DEFAULT" \
  "Generate a short, entirely fictional customer support ticket transcript for a QA test. Include a clearly fake SSN in XXX-XX-XXXX format, a fake 16-digit credit card number, a fake email address, and a fake phone number - all obviously placeholder values, never real. Output only the ticket text." \
  "generate-fixture" "x-cloptima-team: Platform AI" "x-cloptima-app: $GENERATOR_APP_ID" "x-cloptima-environment: dev"
GENERATED_TICKET="$(jq -r '.choices[0].message.content // empty' "$RESP_BODY_FILE")"
echo "Generated ticket (fed into the guardrail-enforced call below):"
echo "  ${GENERATED_TICKET:0:300}..."
echo ""

call_chat "$(echo "$GUARDED_KEY" | jq -r '.accessToken')" "$MODEL_DEFAULT" \
  "A customer submitted this support ticket. Draft a one-sentence acknowledgement reply.

$GENERATED_TICKET" \
  "pii-guardrail-probe" "x-cloptima-team: Platform AI" "x-cloptima-app: $GUARDED_APP_ID" "x-cloptima-environment: dev"
jq '.' "$RESP_BODY_FILE"

echo ""
echo "Expected: blocked before provider egress (403, detector_pii) - prompt-side PII is denied, not silently"
echo "admitted. guardrailOutputAction: redact applies to generated output, not an incoming sensitive prompt."
echo "Evidence: Audit tab ($CONSOLE_AUDIT) - the block record names the pii/secret detector that fired; Policies tab ($CONSOLE_POLICIES) shows the guardrailDetectorsEnabled config."
