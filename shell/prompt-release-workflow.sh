#!/usr/bin/env bash
# Prompt registry / dataset / eval / release-gate workflow: create a prompt
# template, draft a version, back an eval run with a dataset, and gate
# promotion behind that eval plus a release approval.
#
# An eval run only counts as release-gate evidence for a prompt version when
# created with subjectRef: { recommendation_id: versionId } and targetKind:
# 'prompt_change'. For a production-environment template, activating a
# version checks the release gate and returns a 409 if the release approval
# hasn't been DECIDED yet - and deciding it is the same kind of human-review
# step approval-workflow.sh doesn't script either, so this example expects
# and prints that 409 as the demonstrated behavior, not a failure. No live
# gateway inference call here - this is a content/release-governance flow,
# not a runtime-enforcement one.
# Run standalone: ./prompt-release-workflow.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

SUFFIX="$(run_suffix)"
APP_ID="prompt-release-$SUFFIX"

echo "Creating a production-environment prompt template..."
TEMPLATE=$(graphql \
  'mutation CreateTemplate($input: LLMPromptTemplateInput!) { createLLMPromptTemplate(input: $input) { id name environment } }' \
  "$(jq -n --arg name "prompt-release-workflow-$SUFFIX" --arg appId "$APP_ID" \
    '{input: {name: $name, owner: "cloptima-ai-gateway-examples", description: "Support-ticket acknowledgement prompt (example run)", appId: $appId, environment: "production"}}')")
TEMPLATE=$(echo "$TEMPLATE" | jq -c '.createLLMPromptTemplate')
TEMPLATE_ID=$(echo "$TEMPLATE" | jq -r '.id')
echo "  template $TEMPLATE_ID (environment=$(echo "$TEMPLATE" | jq -r '.environment'))"

echo "Drafting a version (activate: false - direct activate-on-create is never allowed for production templates)..."
VERSION=$(graphql \
  'mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) { createLLMPromptVersion(templateId: $templateId, input: $input) { id status } }' \
  "$(jq -n --arg templateId "$TEMPLATE_ID" \
    '{templateId: $templateId, input: {content: "Draft a one-sentence acknowledgement reply to this customer support ticket:\n\n{{ticket_text}}", changeSummary: "Initial draft", activate: false}}')")
VERSION=$(echo "$VERSION" | jq -c '.createLLMPromptVersion')
VERSION_ID=$(echo "$VERSION" | jq -r '.id')
echo "  version $VERSION_ID (status=$(echo "$VERSION" | jq -r '.status'))"

echo "Creating a dataset to back the eval run..."
DATASET=$(graphql \
  'mutation CreateDataset($input: LLMDatasetInput!) { createLLMDataset(input: $input) { id name recordCount } }' \
  "$(jq -n --arg name "prompt-release-workflow-dataset-$SUFFIX" --arg appId "$APP_ID" \
    '{input: {name: $name, description: "Example dataset for prompt-release-workflow", appId: $appId, isGolden: false}}')")
DATASET=$(echo "$DATASET" | jq -c '.createLLMDataset')
DATASET_ID=$(echo "$DATASET" | jq -r '.id')
echo "  dataset $DATASET_ID (recordCount=$(echo "$DATASET" | jq -r '.recordCount'))"

echo "Running an eval against this version (subjectRef.recommendation_id must equal the version id)..."
EVAL_RUN=$(graphql \
  'mutation CreateEvalRun($input: LLMEvalRunInput!) { createLLMEvalRun(input: $input) { id status passed } }' \
  "$(jq -n --arg datasetId "$DATASET_ID" --arg versionId "$VERSION_ID" \
    '{input: {datasetId: $datasetId, evalType: "deterministic", targetKind: "prompt_change", subjectRef: {recommendation_id: $versionId}, runNow: true}}')")
EVAL_RUN=$(echo "$EVAL_RUN" | jq -c '.createLLMEvalRun')
EVAL_RUN_ID=$(echo "$EVAL_RUN" | jq -r '.id')
echo "  eval run $EVAL_RUN_ID (status=$(echo "$EVAL_RUN" | jq -r '.status'), passed=$(echo "$EVAL_RUN" | jq -r '.passed'))"

echo "Requesting a release approval for the production promotion (subjectKind: prompt_deployment)..."
RELEASE_APPROVAL=$(graphql \
  'mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) { createLLMReleaseApproval(input: $input) { id state subjectKind subjectId } }' \
  "$(jq -n --arg versionId "$VERSION_ID" --arg evalRunId "$EVAL_RUN_ID" \
    '{input: {subjectKind: "prompt_deployment", subjectId: $versionId, evalRunId: $evalRunId}}')")
RELEASE_APPROVAL=$(echo "$RELEASE_APPROVAL" | jq -c '.createLLMReleaseApproval')
echo "  release approval $(echo "$RELEASE_APPROVAL" | jq -r '.id') (state=$(echo "$RELEASE_APPROVAL" | jq -r '.state'))"

echo ""
echo "Attempting to activate the version (expected to be blocked - the release approval above is pending, not decided)..."
ACTIVATE_ERROR_FILE="$(mktemp)"
set +e
ACTIVATED=$(graphql \
  'mutation Activate($templateId: ID!, $versionId: ID!) { activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status } }' \
  "$(jq -n --arg templateId "$TEMPLATE_ID" --arg versionId "$VERSION_ID" '{templateId: $templateId, versionId: $versionId}')" 2>"$ACTIVATE_ERROR_FILE")
ACTIVATE_STATUS=$?
set -e
if [ "$ACTIVATE_STATUS" -eq 0 ]; then
  echo "  activated: $(echo "$ACTIVATED" | jq -c '.activateLLMPromptVersion') (unexpected unless the release approval was already decided on a prior run)"
else
  echo "  blocked: $(cat "$ACTIVATE_ERROR_FILE")"
  echo "  Expected: HTTP 409 - production activation is gated on the release approval being DECIDED, not just"
  echo "  requested. Deciding it (decideLLMReleaseApproval) is a second-identity review step in the console, not"
  echo "  something this script does on the requester's own behalf. Re-run activation after approving in the console."
fi
rm -f "$ACTIVATE_ERROR_FILE"

echo ""
echo "Evidence: Audit tab ($CONSOLE_AUDIT) shows the pending release approval; Policies tab ($CONSOLE_POLICIES) area's prompt registry view remains in draft / pending-release status until approved."
