// Prompt registry / dataset / eval / release-gate workflow: create a prompt
// template, draft a version, back an eval run with a dataset, and gate
// promotion behind that eval plus a release approval.
//
// To demonstrate the evaluation engine's automated validation capability,
// this script first sends baseline requests through the gateway to generate
// audit logs, builds a golden dataset from those logs, and labels them with
// expected outputs. It then runs deterministic evaluation runs: first a failing
// run to show quality gates blocking production activation, and then a passing
// run that allows activation to succeed.
//
// For a production-environment template, activating a version checks the
// release gate and returns a 409 if the release approval hasn't been
// DECIDED yet. At the end, the same release approval is requested again with
// applyImmediately: true. Since this key already qualifies to decide it
// itself and the evaluation is passing, it's approved right away and activation succeeds.
// Run standalone:
//   node src/examples/prompt-release-workflow.mjs
import { runSuffix, CONSOLE, config, USER_AGENT } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const suffix = runSuffix();
  const appId = `prompt-release-${suffix}`;

  console.log('Creating baseline policy and virtual key...');
  const policy = await createPolicy({
    name: `prompt-release-policy-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: ['vertex_ai/gemini-2.5-flash'],
    promptRetentionMode: 'full',
  });

  const key = await createVirtualKey({
    name: `vk-prompt-release-${suffix}`,
    teamId: 'Platform AI',
    appId,
    environment: 'production',
  });
  const accessToken = key.accessToken;

  await createBinding({
    policyId: policy.id,
    teamId: 'Platform AI',
    appId,
    environment: 'production',
    priority: 10,
    acknowledgeOverlap: true,
  });
  console.log('  Policy bound, waiting for binding propagation...');
  await sleep(3000);

  async function callChat(prompt, label) {
    const response = await fetch(`${config.baseUrl}/v1/ai/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'user-agent': USER_AGENT,
        authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({ model: 'vertex_ai/gemini-2.5-flash', messages: [{ role: 'user', content: prompt }] }),
    });
    console.log(`  [${response.status === 200 ? 'allowed' : 'blocked'}] ${label} (http ${response.status})`);
  }

  console.log('Sending live chat calls to generate audit logs...');
  await callChat(
    'In one word (auth/billing/technical), classify this support ticket: I forgot my password, how do I reset it?',
    'ticket-1-auth',
  );
  await callChat(
    'In one word (auth/billing/technical), classify this support ticket: I was charged twice for my premium account.',
    'ticket-2-billing',
  );

  console.log('  Sent requests, waiting for logs to flush...');
  await sleep(3000);

  console.log('Creating a golden dataset filtering by App ID...');
  const { createLLMDataset: dataset } = await graphql(
    `mutation CreateDataset($input: LLMDatasetInput!) {
      createLLMDataset(input: $input) { id name recordCount }
    }`,
    {
      input: {
        name: `prompt-release-workflow-dataset-${suffix}`,
        description: 'Example dataset for prompt-release-workflow',
        appId,
        isGolden: true,
      },
    },
  );
  console.log(`  dataset ${dataset.id} (recordCount=${dataset.recordCount})`);

  if (dataset.recordCount < 2) {
    throw new Error(`Error: Golden dataset contains ${dataset.recordCount} records, expected at least 2!`);
  }

  console.log('Retrieving dataset records to get expected output...');
  const datasetInfo = await graphql(
    `query GetDataset($id: ID!) {
      llmDataset(id: $id, includeRecords: true) {
        id
        records
      }
    }`,
    { id: dataset.id },
  );

  const records = datasetInfo.llmDataset.records;
  // Sort records by created_at ascending to align them with prompt execution order
  records.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  const r1Id = records[0].id;
  const r2Id = records[1].id;
  console.log(`  record 1 ID: ${r1Id} (Expected: auth)`);
  console.log(`  record 2 ID: ${r2Id} (Expected: billing)`);

  console.log('Setting expected output labels on the records...');
  await graphql(
    `mutation SetLabels($input: LLMDatasetLabelsInput!) {
      setLLMDatasetLabels(input: $input) { id }
    }`,
    {
      input: {
        datasetId: dataset.id,
        expectedOutputs: {
          [r1Id]: 'auth',
          [r2Id]: 'billing',
        },
      },
    },
  );

  console.log('Creating a production-environment prompt template...');
  const { createLLMPromptTemplate: template } = await graphql(
    `mutation CreateTemplate($input: LLMPromptTemplateInput!) {
      createLLMPromptTemplate(input: $input) { id name environment }
    }`,
    {
      input: {
        name: `prompt-release-workflow-${suffix}`,
        owner: 'cloptima-ai-gateway-examples',
        description: 'Intent Classifier Prompt',
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
        content: 'Intent Classifier template v1',
        changeSummary: 'Initial version',
        activate: false,
      },
    },
  );
  console.log(`  version ${version.id} (status=${version.status})`);

  console.log('Running deterministic evaluation run with failing candidate output config...');
  // We pass a wrong output for record 2 ('technical' instead of 'billing') to fail the 80% threshold
  const { createLLMEvalRun: evalRunFail } = await graphql(
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
        threshold: 0.8,
        config: {
          candidate_outputs: {
            [r1Id]: 'auth',
            [r2Id]: 'technical',
          },
        },
      },
    },
  );
  console.log(`  failing eval run ${evalRunFail.id} (status=${evalRunFail.status}, passed=${evalRunFail.passed})`);

  console.log('Requesting release approval with applyImmediately: true for the failing eval run...');
  const { createLLMReleaseApproval: releaseApprovalFail } = await graphql(
    `mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
      createLLMReleaseApproval(input: $input) { id state }
    }`,
    {
      input: {
        subjectKind: 'prompt_deployment',
        subjectId: version.id,
        evalRunId: evalRunFail.id,
        applyImmediately: true,
      },
    },
  );
  console.log(`  release approval ${releaseApprovalFail.id} (state=${releaseApprovalFail.state})`);

  console.log('\nAttempting to activate the version (expected to be blocked - the evaluation run failed the quality gate)...');
  try {
    const { activateLLMPromptVersion: activated } = await graphql(
      `mutation Activate($templateId: ID!, $versionId: ID!) {
        activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
      }`,
      { templateId: template.id, versionId: version.id },
    );
    throw new Error(
      'quality gate did not hold: activation succeeded while the release approval was still pending '
      + `(${JSON.stringify(activated)})`,
    );
  } catch (err) {
    if (!/quality gate did not hold/.test(err.message)) {
      console.log(`  blocked: ${err.message}`);
      console.log(
        '  Confirmed: production activation is blocked because the release approval remained pending\n'
        + '  (gate failed due to the latest evaluation run scoring 50% vs required 80% threshold).',
      );
    } else {
      throw err;
    }
  }

  console.log('\nRunning deterministic evaluation run with passing candidate output config...');
  // We pass the correct output ('billing') to satisfy the 80% threshold
  const { createLLMEvalRun: evalRunPass } = await graphql(
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
        threshold: 0.8,
        config: {
          candidate_outputs: {
            [r1Id]: 'auth',
            [r2Id]: 'billing',
          },
        },
      },
    },
  );
  console.log(`  passing eval run ${evalRunPass.id} (status=${evalRunPass.status}, passed=${evalRunPass.passed})`);

  console.log('Requesting release approval with applyImmediately: true for the passing eval run...');
  const { createLLMReleaseApproval: releaseApprovalPass } = await graphql(
    `mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
      createLLMReleaseApproval(input: $input) { id state }
    }`,
    {
      input: {
        subjectKind: 'prompt_deployment',
        subjectId: version.id,
        evalRunId: evalRunPass.id,
        applyImmediately: true,
      },
    },
  );
  console.log(`  release approval ${releaseApprovalPass.id} (state=${releaseApprovalPass.state})`);

  console.log('\nRetrying activation now that the passing release approval is decided...');
  const { activateLLMPromptVersion: activatedPass } = await graphql(
    `mutation Activate($templateId: ID!, $versionId: ID!) {
      activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
    }`,
    { templateId: template.id, versionId: version.id },
  );
  console.log(`  activated: ${JSON.stringify(activatedPass)}`);
  console.log(
    'Expected: this activation succeeds - applyImmediately: true auto-approved the gate because the latest\n'
    + 'evaluation run met the 80% quality threshold.',
  );
  console.log(`\nEvidence: Audit tab (${CONSOLE.audit}) shows both release approvals - the first still pending (failed gate), the second already decided; Policies tab (${CONSOLE.policies}) shows this version now active.`);
}

main().catch((err) => {
  console.error('prompt-release-workflow failed:', err);
  process.exitCode = 1;
});
