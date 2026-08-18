#!/usr/bin/env bash
# Prompt registry / dataset / eval / release-gate workflow: create a prompt
# template, draft a version, back an eval run with a dataset, and gate
# promotion behind that eval plus a release approval.
#
# To demonstrate the evaluation engine's automated validation capability,
# this script first sends a baseline request through the gateway to generate
# an audit log, builds a golden dataset from that log, and labels it with an
# expected output. It then runs a deterministic evaluation run that matches
# the output candidate and auto-passes the run.
#
# For a production-environment template, activating a version checks the
# release gate and returns a 409 if the release approval hasn't been
# DECIDED yet. At the end, the same release approval is requested again with
# applyImmediately: true. Since this key already qualifies to decide it
# itself, it's approved right away and activation is retried successfully.
# Run standalone: ./prompt-release-workflow.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

SUFFIX="$(run_suffix)"
APP_ID="prompt-release-$SUFFIX"

echo "Creating baseline policy and virtual key..."
POLICY=$(create_policy "$(jq -n --arg name "prompt-release-policy-$SUFFIX" --arg model "vertex_ai/gemini-2.5-flash" \
  '{name: $name, mode: "enforce", budgetMode: "hard_fast", allowedProviders: ["vertex_ai"], allowedModels: [$model], promptRetentionMode: "full"}')")
POLICY_ID=$(echo "$POLICY" | jq -r '.id')

KEY=$(create_virtual_key "$(jq -n --arg name "vk-prompt-release-$SUFFIX" --arg appId "$APP_ID" \
  '{name: $name, teamId: "Platform AI", appId: $appId, environment: "production"}')")
ACCESS_TOKEN=$(echo "$KEY" | jq -r '.accessToken')

create_binding "$(jq -n --arg policyId "$POLICY_ID" --arg appId "$APP_ID" \
  '{policyId: $policyId, teamId: "Platform AI", appId: $appId, environment: "production", priority: 10, acknowledgeOverlap: true}')" >/dev/null
echo "  Policy bound, waiting for binding propagation..."
sleep 3

echo "Sending live chat calls to generate audit logs..."
call_chat "$ACCESS_TOKEN" "vertex_ai/gemini-2.5-flash" \
  "In one word (auth/billing/technical), classify this support ticket: I forgot my password, how do I reset it?" \
  "ticket-1-auth"

call_chat "$ACCESS_TOKEN" "vertex_ai/gemini-2.5-flash" \
  "In one word (auth/billing/technical), classify this support ticket: I was charged twice for my premium account." \
  "ticket-2-billing"

echo "  Sent requests, waiting for logs to flush..."
sleep 3

echo "Creating a golden dataset filtering by App ID..."
DATASET=$(graphql \
  'mutation CreateDataset($input: LLMDatasetInput!) { createLLMDataset(input: $input) { id name recordCount } }' \
  "$(jq -n --arg name "prompt-release-workflow-dataset-$SUFFIX" --arg appId "$APP_ID" \
    '{input: {name: $name, description: "Example dataset for prompt-release-workflow", appId: $appId, isGolden: true}}')")
DATASET=$(echo "$DATASET" | jq -c '.createLLMDataset')
DATASET_ID=$(echo "$DATASET" | jq -r '.id')
RECORD_COUNT=$(echo "$DATASET" | jq -r '.recordCount')
echo "  dataset $DATASET_ID (recordCount=$RECORD_COUNT)"

if [ "$RECORD_COUNT" -lt 2 ]; then
  echo "Error: Golden dataset contains $RECORD_COUNT records, expected at least 2!" >&2
  exit 1
fi

echo "Retrieving dataset records to get expected output..."
DATASET_DATA=$(graphql \
  'query GetDataset($id: ID!) {
    llmDataset(id: $id, includeRecords: true) {
      id
      records
    }
  }' "$(jq -n --arg id "$DATASET_ID" '{id: $id}')")

# Sort records by created_at ascending to align them with prompt execution order
RECORDS_SORTED=$(echo "$DATASET_DATA" | jq -c '.llmDataset.records | sort_by(.created_at)')
RECORD_1_ID=$(echo "$RECORDS_SORTED" | jq -r '.[0].id')
RECORD_2_ID=$(echo "$RECORDS_SORTED" | jq -r '.[1].id')
echo "  record 1 ID: $RECORD_1_ID (Expected: auth)"
echo "  record 2 ID: $RECORD_2_ID (Expected: billing)"

echo "Setting expected output labels on the records..."
graphql \
  'mutation SetLabels($input: LLMDatasetLabelsInput!) { setLLMDatasetLabels(input: $input) { id } }' \
  "$(jq -n --arg datasetId "$DATASET_ID" --arg r1 "$RECORD_1_ID" --arg r2 "$RECORD_2_ID" \
    '{input: {datasetId: $datasetId, expectedOutputs: {($r1): "auth", ($r2): "billing"}}}')" >/dev/null

echo "Creating a production-environment prompt template..."
TEMPLATE=$(graphql \
  'mutation CreateTemplate($input: LLMPromptTemplateInput!) { createLLMPromptTemplate(input: $input) { id name environment } }' \
  "$(jq -n --arg name "prompt-release-workflow-$SUFFIX" --arg appId "$APP_ID" \
    '{input: {name: $name, owner: "cloptima-ai-gateway-examples", description: "Intent Classifier Prompt", appId: $appId, environment: "production"}}')")
TEMPLATE=$(echo "$TEMPLATE" | jq -c '.createLLMPromptTemplate')
TEMPLATE_ID=$(echo "$TEMPLATE" | jq -r '.id')
echo "  template $TEMPLATE_ID (environment=$(echo "$TEMPLATE" | jq -r '.environment'))"

echo "Drafting a version (activate: false - direct activate-on-create is never allowed for production templates)..."
VERSION=$(graphql \
  'mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) { createLLMPromptVersion(templateId: $templateId, input: $input) { id status } }' \
  "$(jq -n --arg templateId "$TEMPLATE_ID" \
    '{templateId: $templateId, input: {content: "Intent Classifier template v1", changeSummary: "Initial version", activate: false}}')")
VERSION=$(echo "$VERSION" | jq -c '.createLLMPromptVersion')
VERSION_ID=$(echo "$VERSION" | jq -r '.id')
echo "  version $VERSION_ID (status=$(echo "$VERSION" | jq -r '.status'))"

echo "Running deterministic evaluation run with failing candidate output config..."
# We pass a wrong output for record 2 ('technical' instead of 'billing') to fail the 80% threshold
EVAL_RUN_FAIL=$(graphql \
  'mutation CreateEvalRun($input: LLMEvalRunInput!) { createLLMEvalRun(input: $input) { id status passed } }' \
  "$(jq -n --arg datasetId "$DATASET_ID" --arg versionId "$VERSION_ID" --arg r1 "$RECORD_1_ID" --arg r2 "$RECORD_2_ID" \
    '{input: {datasetId: $datasetId, evalType: "deterministic", targetKind: "prompt_change", subjectRef: {recommendation_id: $versionId}, runNow: true, threshold: 0.8, config: {candidate_outputs: {($r1): "auth", ($r2): "technical"}}}}')")
EVAL_RUN_FAIL=$(echo "$EVAL_RUN_FAIL" | jq -c '.createLLMEvalRun')
EVAL_RUN_FAIL_ID=$(echo "$EVAL_RUN_FAIL" | jq -r '.id')
echo "  failing eval run $EVAL_RUN_FAIL_ID (status=$(echo "$EVAL_RUN_FAIL" | jq -r '.status'), passed=$(echo "$EVAL_RUN_FAIL" | jq -r '.passed'))"

echo "Requesting release approval with applyImmediately: true for the failing eval run..."
RELEASE_APPROVAL_FAIL=$(graphql \
  'mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) { createLLMReleaseApproval(input: $input) { id state } }' \
  "$(jq -n --arg versionId "$VERSION_ID" --arg evalRunId "$EVAL_RUN_FAIL_ID" \
    '{input: {subjectKind: "prompt_deployment", subjectId: $versionId, evalRunId: $evalRunId, applyImmediately: true}}')")
RELEASE_APPROVAL_FAIL=$(echo "$RELEASE_APPROVAL_FAIL" | jq -c '.createLLMReleaseApproval')
echo "  release approval $(echo "$RELEASE_APPROVAL_FAIL" | jq -r '.id') (state=$(echo "$RELEASE_APPROVAL_FAIL" | jq -r '.state'))"

echo ""
echo "Attempting to activate the version (expected to be blocked - the evaluation run failed the quality gate)..."
ACTIVATE_ERROR_FILE="$(mktemp)"
set +e
ACTIVATED_FAIL=$(graphql \
  'mutation Activate($templateId: ID!, $versionId: ID!) { activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status } }' \
  "$(jq -n --arg templateId "$TEMPLATE_ID" --arg versionId "$VERSION_ID" '{templateId: $templateId, versionId: $versionId}')" 2>"$ACTIVATE_ERROR_FILE")
ACTIVATE_STATUS=$?
set -e
if [ "$ACTIVATE_STATUS" -eq 0 ]; then
  echo "  activated: $(echo "$ACTIVATED_FAIL" | jq -c '.activateLLMPromptVersion') (unexpected)"
else
  echo "  blocked: $(cat "$ACTIVATE_ERROR_FILE")"
  echo "  Expected: HTTP 409 - production activation is blocked because the release approval remained pending"
  echo "  (gate failed due to the latest evaluation run scoring 50% vs required 80% threshold)."
fi
rm -f "$ACTIVATE_ERROR_FILE"

echo ""
echo "Running deterministic evaluation run with passing candidate output config..."
# We pass the correct output ('billing') to satisfy the 80% threshold
EVAL_RUN_PASS=$(graphql \
  'mutation CreateEvalRun($input: LLMEvalRunInput!) { createLLMEvalRun(input: $input) { id status passed } }' \
  "$(jq -n --arg datasetId "$DATASET_ID" --arg versionId "$VERSION_ID" --arg r1 "$RECORD_1_ID" --arg r2 "$RECORD_2_ID" \
    '{input: {datasetId: $datasetId, evalType: "deterministic", targetKind: "prompt_change", subjectRef: {recommendation_id: $versionId}, runNow: true, threshold: 0.8, config: {candidate_outputs: {($r1): "auth", ($r2): "billing"}}}}')")
EVAL_RUN_PASS=$(echo "$EVAL_RUN_PASS" | jq -c '.createLLMEvalRun')
EVAL_RUN_PASS_ID=$(echo "$EVAL_RUN_PASS" | jq -r '.id')
echo "  passing eval run $EVAL_RUN_PASS_ID (status=$(echo "$EVAL_RUN_PASS" | jq -r '.status'), passed=$(echo "$EVAL_RUN_PASS" | jq -r '.passed'))"

echo "Requesting release approval with applyImmediately: true for the passing eval run..."
RELEASE_APPROVAL_PASS=$(graphql \
  'mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) { createLLMReleaseApproval(input: $input) { id state } }' \
  "$(jq -n --arg versionId "$VERSION_ID" --arg evalRunId "$EVAL_RUN_PASS_ID" \
    '{input: {subjectKind: "prompt_deployment", subjectId: $versionId, evalRunId: $evalRunId, applyImmediately: true}}')")
RELEASE_APPROVAL_PASS=$(echo "$RELEASE_APPROVAL_PASS" | jq -c '.createLLMReleaseApproval')
echo "  release approval $(echo "$RELEASE_APPROVAL_PASS" | jq -r '.id') (state=$(echo "$RELEASE_APPROVAL_PASS" | jq -r '.state'))"

echo ""
echo "Retrying activation now that the passing release approval is decided..."
ACTIVATED_PASS=$(graphql \
  'mutation Activate($templateId: ID!, $versionId: ID!) { activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status } }' \
  "$(jq -n --arg templateId "$TEMPLATE_ID" --arg versionId "$VERSION_ID" '{templateId: $templateId, versionId: $versionId}')")
echo "  activated: $(echo "$ACTIVATED_PASS" | jq -c '.activateLLMPromptVersion')"
echo "Expected: this activation succeeds - applyImmediately: true auto-approved the gate because the latest"
echo "evaluation run met the 80% quality threshold."
echo ""
echo "Evidence: Audit tab ($CONSOLE_AUDIT) shows both release approvals - the first still pending (failed gate), the second already decided; Policies tab ($CONSOLE_POLICIES) shows this version now active."
