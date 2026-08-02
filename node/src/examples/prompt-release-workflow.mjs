// Prompt registry / dataset / eval / release-gate workflow: create a prompt
// template, draft a version, back an eval run with a dataset, and gate
// promotion behind that eval plus a release approval.
//
// An eval run only counts as release-gate evidence for a prompt version when
// created with subjectRef: { recommendation_id: versionId } and targetKind:
// 'prompt_change'. For a production-environment template, activating a
// version checks the release gate and returns a 409 if the release approval
// hasn't been DECIDED yet - and deciding it is the same kind of human-review
// step approval-workflow.mjs doesn't script either, so this example expects
// and prints that 409 as the demonstrated behavior, not a failure. No live
// gateway inference call here - this is a content/release-governance flow,
// not a runtime-enforcement one.
// Run standalone:
//   node src/examples/prompt-release-workflow.mjs
import { runSuffix, CONSOLE } from '../lib/config.mjs';
import { graphql } from '../lib/gatewayAdmin.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `prompt-release-${suffix}`;

  console.log('Creating a production-environment prompt template...');
  const { createLLMPromptTemplate: template } = await graphql(
    `mutation CreateTemplate($input: LLMPromptTemplateInput!) {
      createLLMPromptTemplate(input: $input) { id name environment }
    }`,
    {
      input: {
        name: `prompt-release-workflow-${suffix}`,
        owner: 'cloptima-ai-gateway-examples',
        description: 'Support-ticket acknowledgement prompt (example run)',
        appId, environment: 'production',
      },
    },
  );
  console.log(`  template ${template.id} (environment=${template.environment})`);

  console.log('Drafting a version (activate: false - direct activate-on-create is never allowed for production templates)...');
  const { createLLMPromptVersion: version } = await graphql(
    `mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) {
      createLLMPromptVersion(templateId: $templateId, input: $input) { id status }
    }`,
    {
      templateId: template.id,
      input: {
        content: 'Draft a one-sentence acknowledgement reply to this customer support ticket:\n\n{{ticket_text}}',
        changeSummary: 'Initial draft',
        activate: false,
      },
    },
  );
  console.log(`  version ${version.id} (status=${version.status})`);

  console.log('Creating a dataset to back the eval run...');
  const { createLLMDataset: dataset } = await graphql(
    `mutation CreateDataset($input: LLMDatasetInput!) {
      createLLMDataset(input: $input) { id name recordCount }
    }`,
    {
      input: {
        name: `prompt-release-workflow-dataset-${suffix}`,
        description: 'Example dataset for prompt-release-workflow',
        appId,
        isGolden: false,
      },
    },
  );
  console.log(`  dataset ${dataset.id} (recordCount=${dataset.recordCount})`);

  console.log("Running an eval against this version (subjectRef.recommendation_id must equal the version id)...");
  const { createLLMEvalRun: evalRun } = await graphql(
    `mutation CreateEvalRun($input: LLMEvalRunInput!) {
      createLLMEvalRun(input: $input) { id status passed }
    }`,
    {
      input: {
        datasetId: dataset.id,
        evalType: 'deterministic',
        targetKind: 'prompt_change',
        subjectRef: { recommendation_id: version.id },
        runNow: true,
      },
    },
  );
  console.log(`  eval run ${evalRun.id} (status=${evalRun.status}, passed=${evalRun.passed})`);

  console.log('Requesting a release approval for the production promotion (subjectKind: prompt_deployment)...');
  const { createLLMReleaseApproval: releaseApproval } = await graphql(
    `mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
      createLLMReleaseApproval(input: $input) { id state subjectKind subjectId }
    }`,
    {
      input: {
        subjectKind: 'prompt_deployment',
        subjectId: version.id,
        evalRunId: evalRun.id,
      },
    },
  );
  console.log(`  release approval ${releaseApproval.id} (state=${releaseApproval.state})`);

  console.log('\nAttempting to activate the version (expected to be blocked - the release approval above is pending, not decided)...');
  try {
    const { activateLLMPromptVersion: activated } = await graphql(
      `mutation Activate($templateId: ID!, $versionId: ID!) {
        activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
      }`,
      { templateId: template.id, versionId: version.id },
    );
    console.log(`  activated: ${JSON.stringify(activated)} (unexpected unless the release approval was already decided on a prior run)`);
  } catch (err) {
    console.log(`  blocked: ${err.message}`);
    console.log(
      "  Expected: HTTP 409 - production activation is gated on the release approval being DECIDED, not just "
      + 'requested. Deciding it (decideLLMReleaseApproval) is a second-identity review step in the console, not '
      + 'something this script does on the requester\'s own behalf. Re-run activation after approving in the console.',
    );
  }

  console.log(`\nEvidence: Audit tab (${CONSOLE.audit}) shows the pending release approval; Policies tab (${CONSOLE.policies}) area's prompt registry view remains in draft / pending-release status until approved.`);
}

main().catch((err) => {
  console.error('prompt-release-workflow failed:', err);
  process.exitCode = 1;
});
